//
//  CPUFrequencyReal.mm
//  Helium
//
//  Reads the CPU's *actual* running clock from IOReport — the source `powermetrics`
//  itself uses.
//
//  ## Why this exists next to CPUFrequencyProbe.mm
//
//  The busy-loop probe measures "how fast the core runs once it is pinned to the
//  top", which is the *peak achievable* clock — it barely moves with load. What a
//  user watching a CPU readout wants is the clock the cores are *actually running
//  at right now*, and that only exists as "time spent in each DVFS state".
//
//  IOReport publishes exactly that: a residency histogram per cluster. Weight each
//  state's residency by that state's frequency (from the device tree's
//  voltage-states table) and you get the average clock over the sampling window —
//  which is the number powermetrics prints.
//
//  ## The chain, and why every step is optional
//
//    1. resolve IOReport's private symbols (dlopen/dlsym; missing -> degrade)
//    2. subscribe to group "CPU Stats" / subgroup "CPU Complex Performance States"
//    3. take two samples 100 ms apart and diff them -> residency per state
//    4. read voltage-states*-sram from IORegistry's AppleARMIODevice -> freq per state
//    5. weight: freq = sum(residency_i * freq_i) / sum(residency_i)
//
//  Any step failing returns 0 so the caller falls back to the busy-loop probe.
//  Nothing here is allowed to crash the HUD: every symbol is resolved by name and
//  checked, and the whole body is wrapped so a surprise degrades to 0.
//
//  ## Memory management (learned from the CPU temperature widget)
//
//  IOReport exposes no documented way to release a subscription, and CFRelease on
//  one can take the HUD down — so the subscription is created **once** and reused.
//  Channel sets and samples are ordinary CF objects and are released normally.
//
//  ## What still needs verification on device
//
//  The group / subgroup / state-key names below are taken from **measured macOS
//  (M-series) results** — kennss/SiliconScope's ioreport-channels.md and
//  vladkens/macmon. **Whether iOS / A-series uses the same names is NOT verified.**
//  So the code tries a list of candidates rather than hard-coding one, and
//  helium_real_cpu_frequency_diagnosis() dumps every group/channel/state it could
//  actually enumerate. One run on the device tells us which name to use.
//

#import "CPUFrequencyReal.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <time.h>

// ---------------------------------------------------------------------------
// IOReport symbols (private; resolved at runtime)
// ---------------------------------------------------------------------------

typedef void *IORepSubRef;

typedef CFMutableDictionaryRef (*fn_CopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef CFMutableDictionaryRef (*fn_CopyAllChannels)(uint64_t, uint64_t);
typedef IORepSubRef (*fn_CreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*fn_CreateSamples)(IORepSubRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*fn_CreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*fn_ChannelGetChannelName)(CFDictionaryRef);
typedef CFStringRef (*fn_ChannelGetGroup)(CFDictionaryRef);
typedef CFStringRef (*fn_ChannelGetSubGroup)(CFDictionaryRef);
typedef CFStringRef (*fn_ChannelGetUnitLabel)(CFDictionaryRef);
typedef long (*fn_SimpleGetIntegerValue)(CFDictionaryRef, int);
typedef int (*fn_StateGetCount)(CFDictionaryRef);
typedef CFStringRef (*fn_StateGetNameForIndex)(CFDictionaryRef, int);
typedef int64_t (*fn_StateGetResidency)(CFDictionaryRef, int);

// ---------------------------------------------------------------------------
// IOKit symbols (also private on iOS; resolved at runtime)
// ---------------------------------------------------------------------------

typedef unsigned int io_object_t;
typedef unsigned int io_iterator_t;
typedef unsigned int io_registry_entry_t;

typedef CFMutableDictionaryRef (*fn_IOServiceMatching)(const char *);
typedef int (*fn_IOServiceGetMatchingServices)(mach_port_t, CFDictionaryRef, io_iterator_t *);
typedef io_object_t (*fn_IOIteratorNext)(io_iterator_t);
typedef int (*fn_IOObjectRelease)(io_object_t);
typedef CFTypeRef (*fn_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t);
typedef io_registry_entry_t (*fn_IORegistryEntryFromPath)(mach_port_t, CFStringRef);

static BOOL gSymbolsTried = NO;
static BOOL gSymbolsOK = NO;

static fn_CopyChannelsInGroup pCopyChannelsInGroup = NULL;
static fn_CopyAllChannels pCopyAllChannels = NULL;
static fn_CreateSubscription pCreateSubscription = NULL;
static fn_CreateSamples pCreateSamples = NULL;
static fn_CreateSamplesDelta pCreateSamplesDelta = NULL;
static fn_ChannelGetChannelName pChannelGetChannelName = NULL;
static fn_ChannelGetGroup pChannelGetGroup = NULL;
static fn_ChannelGetSubGroup pChannelGetSubGroup = NULL;
static fn_ChannelGetUnitLabel pChannelGetUnitLabel = NULL;
static fn_SimpleGetIntegerValue pSimpleGetIntegerValue = NULL;
static fn_StateGetCount pStateGetCount = NULL;
static fn_StateGetNameForIndex pStateGetNameForIndex = NULL;
static fn_StateGetResidency pStateGetResidency = NULL;

static fn_IOServiceMatching pIOServiceMatching = NULL;
static fn_IOServiceGetMatchingServices pIOServiceGetMatchingServices = NULL;
static fn_IOIteratorNext pIOIteratorNext = NULL;
static fn_IOObjectRelease pIOObjectRelease = NULL;
static fn_IORegistryEntryCreateCFProperty pIORegistryEntryCreateCFProperty = NULL;
static fn_IORegistryEntryFromPath pIORegistryEntryFromPath = NULL;

static void *gIOKitHandle = NULL;

// IOKit.framework is already linked in (Makefile PRIVATE_FRAMEWORKS), so its
// symbols usually live in the default namespace. Same two-step lookup the CPU
// temperature widget uses: default namespace first, then a dlopen()ed handle.
static void *heliumResolveSymbol(const char *name)
{
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;

    if (!gIOKitHandle) {
        gIOKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!gIOKitHandle) {
            gIOKitHandle = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        }
    }
    return gIOKitHandle ? dlsym(gIOKitHandle, name) : NULL;
}

static BOOL ensureSymbols(void)
{
    if (gSymbolsTried) return gSymbolsOK;
    gSymbolsTried = YES;

    pCopyChannelsInGroup = (fn_CopyChannelsInGroup)heliumResolveSymbol("IOReportCopyChannelsInGroup");
    pCopyAllChannels     = (fn_CopyAllChannels)heliumResolveSymbol("IOReportCopyAllChannels");
    pCreateSubscription  = (fn_CreateSubscription)heliumResolveSymbol("IOReportCreateSubscription");
    pCreateSamples       = (fn_CreateSamples)heliumResolveSymbol("IOReportCreateSamples");
    pCreateSamplesDelta  = (fn_CreateSamplesDelta)heliumResolveSymbol("IOReportCreateSamplesDelta");
    pChannelGetChannelName = (fn_ChannelGetChannelName)heliumResolveSymbol("IOReportChannelGetChannelName");
    pChannelGetGroup     = (fn_ChannelGetGroup)heliumResolveSymbol("IOReportChannelGetGroup");
    pChannelGetSubGroup  = (fn_ChannelGetSubGroup)heliumResolveSymbol("IOReportChannelGetSubGroup");
    pChannelGetUnitLabel = (fn_ChannelGetUnitLabel)heliumResolveSymbol("IOReportChannelGetUnitLabel");
    pSimpleGetIntegerValue = (fn_SimpleGetIntegerValue)heliumResolveSymbol("IOReportSimpleGetIntegerValue");
    pStateGetCount       = (fn_StateGetCount)heliumResolveSymbol("IOReportStateGetCount");
    pStateGetNameForIndex = (fn_StateGetNameForIndex)heliumResolveSymbol("IOReportStateGetNameForIndex");
    pStateGetResidency   = (fn_StateGetResidency)heliumResolveSymbol("IOReportStateGetResidency");

    pIOServiceMatching   = (fn_IOServiceMatching)heliumResolveSymbol("IOServiceMatching");
    pIOServiceGetMatchingServices = (fn_IOServiceGetMatchingServices)heliumResolveSymbol("IOServiceGetMatchingServices");
    pIOIteratorNext      = (fn_IOIteratorNext)heliumResolveSymbol("IOIteratorNext");
    pIOObjectRelease     = (fn_IOObjectRelease)heliumResolveSymbol("IOObjectRelease");
    pIORegistryEntryCreateCFProperty = (fn_IORegistryEntryCreateCFProperty)heliumResolveSymbol("IORegistryEntryCreateCFProperty");
    pIORegistryEntryFromPath = (fn_IORegistryEntryFromPath)heliumResolveSymbol("IORegistryEntryFromPath");

    gSymbolsOK = (pCopyChannelsInGroup && pCreateSubscription && pCreateSamples &&
                  pCreateSamplesDelta && pChannelGetChannelName && pStateGetCount &&
                  pStateGetNameForIndex && pStateGetResidency);
    return gSymbolsOK;
}

// ---------------------------------------------------------------------------
// DVFS frequency table
// ---------------------------------------------------------------------------

// Candidate keys, most-likely first. macOS measured values: 1-sram = E cluster,
// 5-sram = P cluster. iOS/A-series keys are unverified — we try the whole family.
static NSArray<NSString *> *const kPClusterKeys = @[ @"voltage-states5-sram",
                                                     @"voltage-states5",
                                                     @"voltage-states2-sram",
                                                     @"voltage-states1-sram" ];
static NSArray<NSString *> *const kEClusterKeys = @[ @"voltage-states1-sram",
                                                     @"voltage-states1",
                                                     @"voltage-states0-sram" ];

/// Reads a raw property from the first matching IORegistry node.
static CFTypeRef copyRegistryPropertyForService(const char *serviceName, CFStringRef key)
{
    if (!pIOServiceMatching || !pIOServiceGetMatchingServices ||
        !pIOIteratorNext || !pIOObjectRelease || !pIORegistryEntryCreateCFProperty) {
        return NULL;
    }

    CFMutableDictionaryRef match = pIOServiceMatching(serviceName);
    if (!match) return NULL;

    io_iterator_t iter = 0;
    if (pIOServiceGetMatchingServices(0, match, &iter) != 0 || !iter) {
        return NULL;
    }

    io_object_t entry = pIOIteratorNext(iter);
    pIOObjectRelease(iter);
    if (!entry) return NULL;

    CFTypeRef value = pIORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    pIOObjectRelease(entry);
    return value;
}

/// Parses a voltage-states blob (array of UInt32 pairs: freqHz, voltage) into an
/// ascending array of MHz. Returns nil when the blob is missing or malformed.
static NSArray<NSNumber *> *parseVoltageStates(CFTypeRef blob)
{
    if (!blob || CFGetTypeID(blob) != CFDataGetTypeID()) return nil;

    CFDataRef data = (CFDataRef)blob;
    CFIndex bytes = CFDataGetLength(data);
    if (bytes < 8) return nil;

    const uint8_t *raw = CFDataGetBytePtr(data);
    CFIndex pairs = bytes / 8;
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)pairs];

    for (CFIndex i = 0; i < pairs; i++) {
        uint32_t freqHz = 0;
        memcpy(&freqHz, raw + i * 8, sizeof(freqHz));
        if (freqHz == 0) continue;              // zero entries are padding
        [out addObject:@(freqHz / 1000000u)];   // Hz -> MHz
    }
    return out.count > 0 ? out : nil;
}

/// Looks for a voltage-states table under AppleARMIODevice (macOS) and, failing
/// that, under the device-tree arm-io node (the iOS shape we have not verified).
static NSArray<NSNumber *> *copyFrequenciesForKeys(NSArray<NSString *> *keys, NSString **foundKeyOut)
{
    for (NSString *key in keys) {
        CFStringRef cfKey = (__bridge CFStringRef)key;

        CFTypeRef blob = copyRegistryPropertyForService("AppleARMIODevice", cfKey);
        NSArray<NSNumber *> *freqs = parseVoltageStates(blob);
        if (blob) CFRelease(blob);
        if (freqs) {
            if (foundKeyOut) *foundKeyOut = key;
            return freqs;
        }

        if (pIORegistryEntryFromPath && pIORegistryEntryCreateCFProperty) {
            io_registry_entry_t node = pIORegistryEntryFromPath(0, CFSTR("IODeviceTree:/arm-io"));
            if (node) {
                CFTypeRef treeBlob = pIORegistryEntryCreateCFProperty(node, cfKey, kCFAllocatorDefault, 0);
                if (pIOObjectRelease) pIOObjectRelease(node);
                NSArray<NSNumber *> *treeFreqs = parseVoltageStates(treeBlob);
                if (treeBlob) CFRelease(treeBlob);
                if (treeFreqs) {
                    if (foundKeyOut) *foundKeyOut = [key stringByAppendingString:@" (device tree)"];
                    return treeFreqs;
                }
            }
        }
    }
    return nil;
}

// Cached once: the DVFS table is fixed hardware data.
static BOOL gFreqTablesTried = NO;
static NSArray<NSNumber *> *gPFreqs = nil;
static NSArray<NSNumber *> *gEFreqs = nil;

static void ensureFreqTables(void)
{
    if (gFreqTablesTried) return;
    gFreqTablesTried = YES;
    gPFreqs = copyFrequenciesForKeys(kPClusterKeys, NULL);
    gEFreqs = copyFrequenciesForKeys(kEClusterKeys, NULL);
}

// ---------------------------------------------------------------------------
// Cached subscription
// ---------------------------------------------------------------------------

static BOOL gSubscriptionTried = NO;
static BOOL gSubscriptionOK = NO;
static IORepSubRef gSubscription = NULL;
static CFMutableDictionaryRef gSubscribedChannels = NULL;

static BOOL ensureFreqSubscription(void)
{
    if (gSubscriptionTried) return gSubscriptionOK;
    gSubscriptionTried = YES;

    // Group/subgroup candidates. macOS measured "CPU Stats" +
    // "CPU Complex Performance States"; the others are cheap alternatives.
    NSArray<NSArray<NSString *> *> *candidates = @[
        @[ @"CPU Stats", @"CPU Complex Performance States" ],
        @[ @"CPU Stats", @"CPU Core Performance States" ],
        @[ @"CPU Stats", @"" ],
    ];

    for (NSArray<NSString *> *candidate in candidates) {
        CFStringRef group = (__bridge CFStringRef)candidate[0];
        CFStringRef subgroup = candidate[1].length ? (__bridge CFStringRef)candidate[1] : NULL;

        CFMutableDictionaryRef channels = pCopyChannelsInGroup(group, subgroup, 0, 0, 0);
        if (!channels) continue;
        if (CFDictionaryGetCount(channels) == 0) { CFRelease(channels); continue; }

        CFMutableDictionaryRef subbed = NULL;
        IORepSubRef sub = pCreateSubscription(NULL, channels, &subbed, 0, NULL);
        if (!sub) {
            CFRelease(channels);
            if (subbed) CFRelease(subbed);
            continue;
        }

        // Only the channels actually subscribed to can be sampled.
        CFMutableDictionaryRef target = subbed ? subbed : channels;
        if (target != channels) CFRelease(channels);

        gSubscription = sub;
        gSubscribedChannels = target;
        gSubscriptionOK = YES;
        return YES;
    }
    return NO;
}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

static NSArray *copyChannelsArrayFromSample(CFDictionaryRef sample)
{
    if (!sample) return nil;
    CFTypeRef channels = CFDictionaryGetValue(sample, CFSTR("IOReportChannels"));
    if (!channels || CFGetTypeID(channels) != CFArrayGetTypeID()) return nil;
    return (__bridge NSArray *)channels;
}

/// Weighted average MHz for one channel, given its DVFS table.
/// Returns 0 when the channel is all-idle or has no usable residency.
static double weightedMHzForChannel(CFDictionaryRef metric, NSArray<NSNumber *> *dvfs)
{
    if (!dvfs || dvfs.count == 0) return 0;

    int states = pStateGetCount(metric);
    if (states <= 1) return 0;

    double weighted = 0.0;
    double total = 0.0;

    for (int i = 1; i < states; i++) {          // state 0 is IDLE
        int64_t residency = pStateGetResidency(metric, i);
        if (residency <= 0) continue;

        NSUInteger freqIndex = (NSUInteger)(i - 1);
        if (freqIndex >= dvfs.count) freqIndex = dvfs.count - 1;
        double mhz = dvfs[freqIndex].doubleValue;

        weighted += (double)residency * mhz;
        total += (double)residency;
    }

    return total > 0 ? weighted / total : 0;
}

typedef struct {
    double pClusterMHz;
    double eClusterMHz;
} ClusterClocks;

static ClusterClocks clocksFromDelta(CFDictionaryRef delta,
                                     NSArray<NSNumber *> *pFreqs,
                                     NSArray<NSNumber *> *eFreqs)
{
    ClusterClocks clocks = { 0, 0 };

    NSArray *channels = copyChannelsArrayFromSample(delta);
    if (!channels) return clocks;

    for (id item in channels) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        CFDictionaryRef metric = (__bridge CFDictionaryRef)item;

        CFStringRef cfName = pChannelGetChannelName ? pChannelGetChannelName(metric) : NULL;
        if (!cfName) continue;
        NSString *upper = ((__bridge NSString *)cfName).uppercaseString;

        if ([upper containsString:@"PCPU"] || [upper hasPrefix:@"P"]) {
            double mhz = weightedMHzForChannel(metric, pFreqs);
            if (mhz > clocks.pClusterMHz) clocks.pClusterMHz = mhz;
        } else if ([upper containsString:@"ECPU"] || [upper hasPrefix:@"E"]) {
            double mhz = weightedMHzForChannel(metric, eFreqs);
            if (mhz > clocks.eClusterMHz) clocks.eClusterMHz = mhz;
        }
    }
    return clocks;
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

uint64_t helium_real_cpu_frequency_mhz(void)
{
    uint64_t result = 0;

    @try {
        if (!ensureSymbols()) return 0;
        if (!ensureFreqSubscription()) return 0;

        ensureFreqTables();
        if (!gPFreqs && !gEFreqs) return 0;     // no DVFS table -> residency is meaningless

        CFDictionaryRef s1 = pCreateSamples(gSubscription, gSubscribedChannels, NULL);
        if (!s1) return 0;

        struct timespec ts = { 0, 100 * 1000 * 1000 };   // 100 ms window
        nanosleep(&ts, NULL);

        CFDictionaryRef s2 = pCreateSamples(gSubscription, gSubscribedChannels, NULL);
        if (!s2) { CFRelease(s1); return 0; }

        CFDictionaryRef delta = pCreateSamplesDelta(s1, s2, NULL);
        if (delta) {
            ClusterClocks clocks = clocksFromDelta(delta, gPFreqs, gEFreqs);
            // Prefer the performance cluster; fall back to E when P is idle.
            double chosen = clocks.pClusterMHz > 0 ? clocks.pClusterMHz : clocks.eClusterMHz;
            if (chosen > 0) result = (uint64_t)(chosen + 0.5);
            CFRelease(delta);
        }
        CFRelease(s2);
        CFRelease(s1);
    } @catch (NSException *e) {
        result = 0;
    }

    return result;
}

NSString *helium_real_cpu_frequency_diagnosis(void)
{
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== Helium real CPU frequency diagnostics ===\n"];
    [out appendFormat:@"device: %@ / iOS %@\n\n",
        [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];

    @try {
        BOOL ok = ensureSymbols();
        [out appendFormat:@"IOReport symbols: %@\n", ok ? @"resolved" : @"MISSING"];
        [out appendFormat:@"  CopyChannelsInGroup=%d CreateSubscription=%d CreateSamples=%d\n",
            pCopyChannelsInGroup != NULL, pCreateSubscription != NULL, pCreateSamples != NULL];
        [out appendFormat:@"  CreateSamplesDelta=%d StateGetCount=%d StateGetResidency=%d\n",
            pCreateSamplesDelta != NULL, pStateGetCount != NULL, pStateGetResidency != NULL];
        [out appendFormat:@"  IOKit: matching=%d createCFProperty=%d fromPath=%d\n",
            pIOServiceMatching != NULL, pIORegistryEntryCreateCFProperty != NULL,
            pIORegistryEntryFromPath != NULL];

        NSString *pKey = nil;
        NSString *eKey = nil;
        NSArray<NSNumber *> *pFreqs = copyFrequenciesForKeys(kPClusterKeys, &pKey);
        NSArray<NSNumber *> *eFreqs = copyFrequenciesForKeys(kEClusterKeys, &eKey);
        [out appendFormat:@"\nP-cluster table: %@ (%@)\n", pFreqs ?: @"NOT FOUND", pKey ?: @"-"];
        [out appendFormat:@"E-cluster table: %@ (%@)\n", eFreqs ?: @"NOT FOUND", eKey ?: @"-"];

        if (!ok) {
            [out appendString:@"\nStopping: IOReport symbols unavailable.\n"];
        } else {
            // Enumerate every channel group IOReport exposes. If iOS names the group
            // something other than "CPU Stats", this is where it shows up instead of
            // the path silently degrading to the busy-loop probe.
            if (pCopyAllChannels) {
                CFMutableDictionaryRef all = pCopyAllChannels(0, 0);
                if (all) {
                    CFIndex count = CFDictionaryGetCount(all);
                    [out appendFormat:@"\nAll-channels dictionary: %ld entries\n", (long)count];
                    if (count > 0) {
                        const void **keys = (const void **)malloc(sizeof(void *) * (size_t)count);
                        const void **vals = (const void **)malloc(sizeof(void *) * (size_t)count);
                        if (keys && vals) {
                            CFDictionaryGetKeysAndValues(all, keys, vals);
                            for (CFIndex i = 0; i < count; i++) {
                                CFTypeRef k = keys[i];
                                if (k && CFGetTypeID(k) == CFStringGetTypeID()) {
                                    [out appendFormat:@"   group: %@\n", (__bridge NSString *)k];
                                }
                            }
                        }
                        if (keys) free(keys);
                        if (vals) free(vals);
                    }
                    CFRelease(all);
                } else {
                    [out appendString:@"\nIOReportCopyAllChannels returned NULL\n"];
                }
            }

            [out appendString:@"\nEnumerating candidate CPU Stats subscriptions:\n"];
            NSArray<NSArray<NSString *> *> *candidates = @[
                @[ @"CPU Stats", @"CPU Complex Performance States" ],
                @[ @"CPU Stats", @"CPU Core Performance States" ],
                @[ @"CPU Stats", @"" ],
            ];
            for (NSArray<NSString *> *candidate in candidates) {
                CFStringRef group = (__bridge CFStringRef)candidate[0];
                CFStringRef subgroup = candidate[1].length ? (__bridge CFStringRef)candidate[1] : NULL;

                CFMutableDictionaryRef channels = pCopyChannelsInGroup(group, subgroup, 0, 0, 0);
                [out appendFormat:@"\n-- %@ / %@ : channels=%s\n",
                    candidate[0], candidate[1].length ? candidate[1] : @"(all)",
                    channels ? "yes" : "NO"];
                if (!channels) continue;

                CFMutableDictionaryRef subbed = NULL;
                IORepSubRef sub = pCreateSubscription(NULL, channels, &subbed, 0, NULL);
                [out appendFormat:@"   subscription: %s\n", sub ? "ok" : "REFUSED"];
                if (sub) {
                    CFMutableDictionaryRef target = subbed ? subbed : channels;
                    CFDictionaryRef s = pCreateSamples(sub, target, NULL);
                    NSArray *list = copyChannelsArrayFromSample(s);
                    [out appendFormat:@"   channels in sample: %lu\n", (unsigned long)list.count];
                    for (id item in list) {
                        if (![item isKindOfClass:[NSDictionary class]]) continue;
                        CFDictionaryRef metric = (__bridge CFDictionaryRef)item;
                        CFStringRef cfName = pChannelGetChannelName ? pChannelGetChannelName(metric) : NULL;
                        CFStringRef cfGroup = pChannelGetGroup ? pChannelGetGroup(metric) : NULL;
                        CFStringRef cfSub = pChannelGetSubGroup ? pChannelGetSubGroup(metric) : NULL;
                        NSString *name = cfName ? (__bridge NSString *)cfName : @"?";
                        NSString *grp = cfGroup ? (__bridge NSString *)cfGroup : @"?";
                        NSString *sb = cfSub ? (__bridge NSString *)cfSub : @"?";

                        int states = pStateGetCount ? pStateGetCount(metric) : 0;
                        NSMutableArray<NSString *> *stateNames = [NSMutableArray array];
                        for (int i = 0; i < states && i < 24; i++) {
                            CFStringRef sn = pStateGetNameForIndex ? pStateGetNameForIndex(metric, i) : NULL;
                            if (sn) [stateNames addObject:(__bridge NSString *)sn];
                        }
                        [out appendFormat:@"     [%@|%@] %@  states=%d %@\n",
                            grp, sb, name, states,
                            [stateNames componentsJoinedByString:@","]];
                    }
                    if (s) CFRelease(s);
                }
                // The subscription itself is deliberately not released (see header).
                CFRelease(channels);
            }
        }
    } @catch (NSException *e) {
        [out appendFormat:@"diagnostics failed: %@\n", e.reason];
    }

    for (NSString *path in @[ @"/var/mobile/Documents/HeliumCPUFreqDiag.txt",
                              @"/var/mobile/Media/Downloads/HeliumCPUFreqDiag.txt" ]) {
        @try {
            [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (NSException *e) { }
    }

    return out;
}

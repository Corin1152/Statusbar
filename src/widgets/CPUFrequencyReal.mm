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
//  ## What the device told us (iPhone / iOS 16.5.1, first diagnosis run)
//
//    * every IOReport symbol resolves, including the State API -> the library is
//      present and callable;
//    * IOReportCopyAllChannels returns {QueryOpts, IOReportChannels} — the channel
//      list lives in the **IOReportChannels array**, so counting the outer
//      dictionary's keys (always 2) says nothing about how many channels a group
//      has. That miscount is why the first build reported "channels=yes" and then
//      had every subscription refused;
//    * subscribing to "CPU Stats" was refused -> the group does not carry channels
//      under that name on iOS, so names are now *discovered*, not assumed;
//    * voltage-states was not found under AppleARMIODevice -> the DVFS lookup now
//      walks the whole device tree instead of guessing a node.
//
//  ## The chain, and why every step is optional
//
//    1. resolve IOReport's private symbols (dlopen/dlsym; missing -> degrade)
//    2. discover the group that actually carries per-cluster DVFS residency
//    3. take two samples 100 ms apart and diff them -> residency per state
//    4. read the DVFS frequency table -> freq per state
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

#import "CPUFrequencyReal.h"

#import <dlfcn.h>
#import <mach/mach.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <time.h>

/// The device-tree plane name. Written as a literal because the SDK constant is
/// not exported on iOS.
static const char *const kDeviceTreePlane = "IODeviceTree";

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
typedef int (*fn_IORegistryCreateIterator)(mach_port_t, const char *, uint32_t, io_iterator_t *);
typedef io_object_t (*fn_IOIteratorNext)(io_iterator_t);
typedef int (*fn_IOObjectRelease)(io_object_t);
typedef CFTypeRef (*fn_IORegistryEntryCreateCFProperty)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t);
typedef int (*fn_IORegistryEntryCreateCFProperties)(io_registry_entry_t, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
typedef int (*fn_IORegistryEntryGetPath)(io_registry_entry_t, const char *, char *);

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
static fn_IORegistryCreateIterator pIORegistryCreateIterator = NULL;
static fn_IOIteratorNext pIOIteratorNext = NULL;
static fn_IOObjectRelease pIOObjectRelease = NULL;
static fn_IORegistryEntryCreateCFProperty pIORegistryEntryCreateCFProperty = NULL;
static fn_IORegistryEntryCreateCFProperties pIORegistryEntryCreateCFProperties = NULL;
static fn_IORegistryEntryGetPath pIORegistryEntryGetPath = NULL;

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
    pIORegistryCreateIterator = (fn_IORegistryCreateIterator)heliumResolveSymbol("IORegistryCreateIterator");
    pIOIteratorNext      = (fn_IOIteratorNext)heliumResolveSymbol("IOIteratorNext");
    pIOObjectRelease     = (fn_IOObjectRelease)heliumResolveSymbol("IOObjectRelease");
    pIORegistryEntryCreateCFProperty = (fn_IORegistryEntryCreateCFProperty)heliumResolveSymbol("IORegistryEntryCreateCFProperty");
    pIORegistryEntryCreateCFProperties = (fn_IORegistryEntryCreateCFProperties)heliumResolveSymbol("IORegistryEntryCreateCFProperties");
    pIORegistryEntryGetPath = (fn_IORegistryEntryGetPath)heliumResolveSymbol("IORegistryEntryGetPath");

    gSymbolsOK = (pCopyChannelsInGroup && pCreateSubscription && pCreateSamples &&
                  pCreateSamplesDelta && pChannelGetChannelName && pStateGetCount &&
                  pStateGetNameForIndex && pStateGetResidency);
    return gSymbolsOK;
}

// ---------------------------------------------------------------------------
// Channel-set helpers
// ---------------------------------------------------------------------------

// The dictionary IOReport hands back is {QueryOpts, IOReportChannels}; the actual
// channel dictionaries live in that array. Counting the outer dictionary's keys
// (always 2) therefore says nothing — this is the count that matters.
static CFArrayRef channelArrayOf(CFDictionaryRef channelSet)
{
    if (!channelSet) return NULL;
    CFTypeRef arr = CFDictionaryGetValue(channelSet, CFSTR("IOReportChannels"));
    if (!arr || CFGetTypeID(arr) != CFArrayGetTypeID()) return NULL;
    return (CFArrayRef)arr;
}

static CFIndex channelCountOf(CFDictionaryRef channelSet)
{
    CFArrayRef arr = channelArrayOf(channelSet);
    return arr ? CFArrayGetCount(arr) : 0;
}

static NSString *channelGroupKey(CFDictionaryRef channel)
{
    CFStringRef g = pChannelGetGroup ? pChannelGetGroup(channel) : NULL;
    CFStringRef s = pChannelGetSubGroup ? pChannelGetSubGroup(channel) : NULL;
    return [NSString stringWithFormat:@"%@ | %@",
            g ? (__bridge NSString *)g : @"?",
            s ? (__bridge NSString *)s : @"?"];
}

// ---------------------------------------------------------------------------
// DVFS frequency table
// ---------------------------------------------------------------------------

// Candidate keys, most-likely first. macOS measured values: 1-sram = E cluster,
// 5-sram = P cluster. iOS keys are unverified — the whole family is tried, and the
// device tree is then searched for any property whose name contains
// "voltage-states".
static NSArray<NSString *> *const kPClusterKeys = @[ @"voltage-states5-sram",
                                                     @"voltage-states5",
                                                     @"voltage-states2-sram",
                                                     @"voltage-states1-sram" ];
static NSArray<NSString *> *const kEClusterKeys = @[ @"voltage-states1-sram",
                                                     @"voltage-states1",
                                                     @"voltage-states0-sram" ];

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

static NSString *registryPathOf(io_registry_entry_t entry)
{
    if (!pIORegistryEntryGetPath) return @"?";
    char path[512] = { 0 };
    if (pIORegistryEntryGetPath(entry, kDeviceTreePlane, path) != 0) return @"?";
    return [NSString stringWithUTF8String:path] ?: @"?";
}

/// Walks the whole device tree looking for a property whose name contains
/// "voltage-states". Returns the first parseable table and records where it came
/// from, so the next build can look there directly.
static NSArray<NSNumber *> *searchDeviceTreeForVoltageStates(NSString **pathOut, NSString **keyOut)
{
    if (!pIORegistryCreateIterator || !pIOIteratorNext || !pIOObjectRelease ||
        !pIORegistryEntryCreateCFProperties) {
        return nil;
    }

    io_iterator_t iter = 0;
    // 1 == kIORegistryIterateRecursively
    if (pIORegistryCreateIterator(0, kDeviceTreePlane, 1, &iter) != 0 || !iter) {
        return nil;
    }

    NSArray<NSNumber *> *result = nil;
    io_object_t entry = 0;
    int visited = 0;

    while ((entry = pIOIteratorNext(iter))) {
        visited++;
        if (visited > 4000) { pIOObjectRelease(entry); break; }

        CFMutableDictionaryRef props = NULL;
        if (pIORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == 0 && props) {
            CFIndex n = CFDictionaryGetCount(props);
            if (n > 0) {
                const void **keys = (const void **)malloc(sizeof(void *) * (size_t)n);
                const void **vals = (const void **)malloc(sizeof(void *) * (size_t)n);
                if (keys && vals) {
                    CFDictionaryGetKeysAndValues(props, keys, vals);
                    for (CFIndex i = 0; i < n; i++) {
                        CFTypeRef k = keys[i];
                        if (!k || CFGetTypeID(k) != CFStringGetTypeID()) continue;
                        NSString *keyName = (__bridge NSString *)k;
                        if ([keyName rangeOfString:@"voltage-states"].location == NSNotFound) continue;

                        NSArray<NSNumber *> *parsed = parseVoltageStates(vals[i]);
                        if (parsed && !result) {
                            result = parsed;
                            if (pathOut) *pathOut = registryPathOf(entry);
                            if (keyOut) *keyOut = keyName;
                        }
                    }
                }
                if (keys) free(keys);
                if (vals) free(vals);
            }
            CFRelease(props);
        }
        pIOObjectRelease(entry);
        if (result) break;
    }
    pIOObjectRelease(iter);
    return result;
}

/// Looks in the two places a table can live: a service property (macOS shape) and
/// the device tree (the iOS shape we are now searching for).
static NSArray<NSNumber *> *copyFrequenciesForKeys(NSArray<NSString *> *keys, NSString **foundKeyOut)
{
    if (pIOServiceMatching && pIOServiceGetMatchingServices && pIOIteratorNext &&
        pIOObjectRelease && pIORegistryEntryCreateCFProperty) {
        for (NSString *key in keys) {
            CFMutableDictionaryRef match = pIOServiceMatching("AppleARMIODevice");
            if (!match) break;
            io_iterator_t iter = 0;
            if (pIOServiceGetMatchingServices(0, match, &iter) != 0 || !iter) continue;

            io_object_t entry = pIOIteratorNext(iter);
            pIOObjectRelease(iter);
            if (!entry) continue;

            CFTypeRef blob = pIORegistryEntryCreateCFProperty(entry, (__bridge CFStringRef)key,
                                                             kCFAllocatorDefault, 0);
            pIOObjectRelease(entry);
            NSArray<NSNumber *> *freqs = parseVoltageStates(blob);
            if (blob) CFRelease(blob);
            if (freqs) {
                if (foundKeyOut) *foundKeyOut = [key stringByAppendingString:@" (AppleARMIODevice)"];
                return freqs;
            }
        }
    }

    NSString *path = nil;
    NSString *key = nil;
    NSArray<NSNumber *> *found = searchDeviceTreeForVoltageStates(&path, &key);
    if (found && foundKeyOut) {
        *foundKeyOut = [NSString stringWithFormat:@"%@ @ %@", key ?: @"?", path ?: @"?"];
    }
    return found;
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
// Subscription: discover the group instead of assuming its name
// ---------------------------------------------------------------------------

static BOOL gSubscriptionTried = NO;
static BOOL gSubscriptionOK = NO;
static IORepSubRef gSubscription = NULL;
static CFMutableDictionaryRef gSubscribedChannels = NULL;
static NSString *gActiveGroupDescription = nil;

/// Tries to subscribe to one channel set.
static BOOL trySubscribe(CFStringRef group, CFStringRef subgroup,
                         IORepSubRef *subOut, CFMutableDictionaryRef *channelsOut)
{
    if (!pCopyChannelsInGroup || !pCreateSubscription) return NO;

    CFMutableDictionaryRef channels = pCopyChannelsInGroup(group, subgroup, 0, 0, 0);
    if (!channels) return NO;

    // A group that does not exist still yields a dictionary — but with an empty
    // IOReportChannels array. That, not the outer key count, is the real test.
    if (channelCountOf(channels) == 0) {
        CFRelease(channels);
        return NO;
    }

    CFMutableDictionaryRef subbed = NULL;
    IORepSubRef sub = pCreateSubscription(NULL, channels, &subbed, 0, NULL);
    if (!sub) {
        CFRelease(channels);
        if (subbed) CFRelease(subbed);
        return NO;
    }

    CFMutableDictionaryRef target = subbed ? subbed : channels;
    if (target != channels) CFRelease(channels);

    *subOut = sub;
    *channelsOut = target;
    return YES;
}

/// Every group/subgroup pair IOReport exposes, derived from the channels
/// themselves (the only place the real names live).
static NSArray<NSString *> *allGroupKeys(void)
{
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    if (!pCopyAllChannels) return @[];

    CFMutableDictionaryRef all = pCopyAllChannels(0, 0);
    if (!all) return @[];
    CFArrayRef arr = channelArrayOf(all);
    if (arr) {
        CFIndex n = CFArrayGetCount(arr);
        for (CFIndex i = 0; i < n; i++) {
            CFDictionaryRef ch = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
            if (ch && CFGetTypeID(ch) == CFDictionaryGetTypeID()) {
                [keys addObject:channelGroupKey(ch)];
            }
        }
    }
    CFRelease(all);
    return [[keys allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL trySubscribeGroupKey(NSString *key)
{
    NSArray<NSString *> *parts = [key componentsSeparatedByString:@" | "];
    if (parts.count != 2) return NO;

    CFStringRef subgroup = [parts[1] isEqualToString:@"?"] ? NULL : (__bridge CFStringRef)parts[1];
    IORepSubRef sub = NULL;
    CFMutableDictionaryRef channels = NULL;
    if (!trySubscribe((__bridge CFStringRef)parts[0], subgroup, &sub, &channels)) return NO;

    gSubscription = sub;
    gSubscribedChannels = channels;
    gActiveGroupDescription = [NSString stringWithFormat:@"%@ (discovered)", key];
    gSubscriptionOK = YES;
    return YES;
}

static BOOL ensureFreqSubscription(void)
{
    if (gSubscriptionTried) return gSubscriptionOK;
    gSubscriptionTried = YES;

    // 1. Known candidates (the macOS-measured names, plus their neighbours).
    NSArray<NSArray<NSString *> *> *candidates = @[
        @[ @"CPU Stats", @"CPU Complex Performance States" ],
        @[ @"CPU Stats", @"CPU Core Performance States" ],
        @[ @"CPU Stats", @"" ],
    ];
    for (NSArray<NSString *> *candidate in candidates) {
        CFStringRef group = (__bridge CFStringRef)candidate[0];
        CFStringRef subgroup = candidate[1].length ? (__bridge CFStringRef)candidate[1] : NULL;
        IORepSubRef sub = NULL;
        CFMutableDictionaryRef channels = NULL;
        if (trySubscribe(group, subgroup, &sub, &channels)) {
            gSubscription = sub;
            gSubscribedChannels = channels;
            gActiveGroupDescription = [NSString stringWithFormat:@"%@ / %@",
                                       candidate[0], candidate[1].length ? candidate[1] : @"(all)"];
            gSubscriptionOK = YES;
            return YES;
        }
    }

    // 2. Discovery: walk every group IOReport knows and subscribe to the first one
    //    that plausibly carries per-cluster clock residency. This is what makes the
    //    path work on iOS even though the macOS name did not.
    for (NSString *key in allGroupKeys()) {
        NSArray<NSString *> *parts = [key componentsSeparatedByString:@" | "];
        if (parts.count != 2) continue;

        NSString *upper = parts[0].uppercaseString;
        if ([upper rangeOfString:@"CPU"].location == NSNotFound &&
            [upper rangeOfString:@"PMP"].location == NSNotFound &&
            [upper rangeOfString:@"PERF"].location == NSNotFound &&
            [upper rangeOfString:@"CLOCK"].location == NSNotFound) {
            continue;
        }
        if (trySubscribeGroupKey(key)) return YES;
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
        [out appendFormat:@"  IOKit: matching=%d createCFProperty=%d createCFProperties=%d iterator=%d path=%d\n",
            pIOServiceMatching != NULL, pIORegistryEntryCreateCFProperty != NULL,
            pIORegistryEntryCreateCFProperties != NULL, pIORegistryCreateIterator != NULL,
            pIORegistryEntryGetPath != NULL];

        NSString *pKey = nil;
        NSString *eKey = nil;
        NSArray<NSNumber *> *pFreqs = copyFrequenciesForKeys(kPClusterKeys, &pKey);
        NSArray<NSNumber *> *eFreqs = copyFrequenciesForKeys(kEClusterKeys, &eKey);
        [out appendFormat:@"\nP-cluster table: %@ (%@)\n", pFreqs ?: @"NOT FOUND", pKey ?: @"-"];
        [out appendFormat:@"E-cluster table: %@ (%@)\n", eFreqs ?: @"NOT FOUND", eKey ?: @"-"];

        if (!ok) {
            [out appendString:@"\nStopping: IOReport symbols unavailable.\n"];
        } else {
            // 1. Every group/subgroup IOReport actually exposes, read off the
            //    channels themselves (the outer dictionary's keys are not groups).
            [out appendString:@"\nGroups IOReport exposes (group | subgroup):\n"];
            NSArray<NSString *> *keys = allGroupKeys();
            if (keys.count == 0) {
                [out appendString:@"   (none — IOReportCopyAllChannels returned nothing usable)\n"];
            } else {
                for (NSString *key in keys) {
                    [out appendFormat:@"   %@\n", key];
                }
            }

            // 2. Which of them can actually be subscribed to, and how many channels
            //    each carries (the number the first build got wrong).
            [out appendString:@"\nSubscription attempts:\n"];
            for (NSString *key in keys) {
                NSArray<NSString *> *parts = [key componentsSeparatedByString:@" | "];
                if (parts.count != 2) continue;

                CFStringRef subgroup = [parts[1] isEqualToString:@"?"]
                    ? NULL : (__bridge CFStringRef)parts[1];
                CFMutableDictionaryRef probe = pCopyChannelsInGroup(
                    (__bridge CFStringRef)parts[0], subgroup, 0, 0, 0);
                CFIndex count = channelCountOf(probe);
                if (probe) CFRelease(probe);

                IORepSubRef sub = NULL;
                CFMutableDictionaryRef channels = NULL;
                BOOL subOK = trySubscribe((__bridge CFStringRef)parts[0], subgroup, &sub, &channels);
                [out appendFormat:@"   %@ : channels=%ld subscribe=%s\n",
                    key, (long)count, subOK ? "ok" : "REFUSED"];
                // The subscription itself is deliberately not released (see header).
            }

            // 3. The channel/state layout of whichever group we ended up using.
            if (ensureFreqSubscription()) {
                [out appendFormat:@"\nActive group: %@\n", gActiveGroupDescription ?: @"?"];
                CFDictionaryRef s = pCreateSamples(gSubscription, gSubscribedChannels, NULL);
                NSArray *list = copyChannelsArrayFromSample(s);
                [out appendFormat:@"   channels: %lu\n", (unsigned long)list.count];
                for (id item in list) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    CFDictionaryRef metric = (__bridge CFDictionaryRef)item;
                    CFStringRef cfName = pChannelGetChannelName ? pChannelGetChannelName(metric) : NULL;
                    NSString *name = cfName ? (__bridge NSString *)cfName : @"?";
                    int states = pStateGetCount ? pStateGetCount(metric) : 0;
                    NSMutableArray<NSString *> *stateNames = [NSMutableArray array];
                    for (int i = 0; i < states && i < 24; i++) {
                        CFStringRef sn = pStateGetNameForIndex ? pStateGetNameForIndex(metric, i) : NULL;
                        if (sn) [stateNames addObject:(__bridge NSString *)sn];
                    }
                    [out appendFormat:@"     %@  states=%d %@\n",
                        name, states, [stateNames componentsJoinedByString:@","]];
                }
                if (s) CFRelease(s);
            } else {
                [out appendString:@"\nNo group could be subscribed to — the real-frequency path is unavailable.\n"];
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

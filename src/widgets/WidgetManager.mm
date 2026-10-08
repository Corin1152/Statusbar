//
//  WidgetManager.m
//  
//
//  Created by lemin on 10/6/23.
//

#import <Foundation/Foundation.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <sys/wait.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <objc/runtime.h>
#import "WidgetManager.h"
#import <IOKit/IOKitLib.h>
#import "../extensions/LunarDate.h"
#import "../extensions/FontUtils.h"

// Thanks to: https://github.com/lwlsw/NetworkSpeed13

#define KILOBITS 1000
#define MEGABITS 1000000
#define GIGABITS 1000000000
#define KILOBYTES (1 << 10)
#define MEGABYTES (1 << 20)
#define GIGABYTES (1 << 30)
#define SHOW_ALWAYS 1
// #define INLINE_SEPARATOR "\t"

// #pragma mark - Formatting Methods
// static unsigned char getSeparator(NSMutableAttributedString *currentAttributed)
// {
//     return [[currentAttributed string] isEqualToString:@""] ? *"" : *"\t";
// }

#pragma mark - Widget-specific Variables
// MARK: 0 - Date Widget
static NSDateFormatter *formatter = nil;

// MARK: Net Speed Widget
static uint8_t DATAUNIT = 0;

typedef struct {
    uint64_t inputBytes;
    uint64_t outputBytes;
} UpDownBytes;

static uint64_t prevOutputBytes = 0, prevInputBytes = 0;
static NSAttributedString *attributedUploadPrefix = nil;
static NSAttributedString *attributedDownloadPrefix = nil;
static NSAttributedString *attributedUploadPrefix2 = nil;
static NSAttributedString *attributedDownloadPrefix2 = nil;

#pragma mark - Date Widget
static NSString* formattedDate(NSString *dateFormat, NSString *dateLocale)
{
    if (!formatter) {
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:dateLocale];
    }
    NSDate *currentDate = [NSDate date];
    NSString *newDateFormat = [LunarDate getChineseCalendarWithDate:currentDate format:dateFormat];
    [formatter setDateFormat:newDateFormat];
    return [formatter stringFromDate:currentDate];
}

#pragma mark - Net Speed Widgets
static UpDownBytes getUpDownBytes()
{
    struct ifaddrs *ifa_list = 0, *ifa;
    UpDownBytes upDownBytes;
    upDownBytes.inputBytes = 0;
    upDownBytes.outputBytes = 0;
    
    if (getifaddrs(&ifa_list) == -1) return upDownBytes;

    for (ifa = ifa_list; ifa; ifa = ifa->ifa_next)
    {
        /* Skip invalid interfaces */
        if (ifa->ifa_name == NULL || ifa->ifa_addr == NULL || ifa->ifa_data == NULL)
            continue;
        
        /* Skip interfaces that are not link level interfaces */
        if (AF_LINK != ifa->ifa_addr->sa_family)
            continue;

        /* Skip interfaces that are not up or running */
        if (!(ifa->ifa_flags & IFF_UP) && !(ifa->ifa_flags & IFF_RUNNING))
            continue;
        
        /* Skip interfaces that are not ethernet or cellular */
        if (strncmp(ifa->ifa_name, "en", 2) && strncmp(ifa->ifa_name, "pdp_ip", 6))
            continue;
        
        struct if_data *if_data = (struct if_data *)ifa->ifa_data;
        
        upDownBytes.inputBytes += if_data->ifi_ibytes;
        upDownBytes.outputBytes += if_data->ifi_obytes;
    }
    
    freeifaddrs(ifa_list);
    return upDownBytes;
}

static NSString* formattedSpeed(uint64_t bytes, NSInteger minUnit)
{
    if (0 == DATAUNIT) {
        // Get min units first
        if (minUnit == 1 && bytes < KILOBYTES) return @"0 KB/s";
        else if (minUnit == 2 && bytes < MEGABYTES) return @"0 MB/s";
        else if (minUnit == 3 && bytes < GIGABYTES) return @"0 GB/s";

        if (bytes < KILOBYTES) return [NSString stringWithFormat:@"%.0f B/s", (double)bytes];
        else if (bytes < MEGABYTES) return [NSString stringWithFormat:@"%.0f KB/s", (double)bytes / KILOBYTES];
        else if (bytes < GIGABYTES) return [NSString stringWithFormat:@"%.2f MB/s", (double)bytes / MEGABYTES];
        else return [NSString stringWithFormat:@"%.2f GB/s", (double)bytes / GIGABYTES];
    } else {
        // Get min units first
        if (minUnit == 1 && bytes < KILOBITS) return @"0 Kb/s";
        else if (minUnit == 2 && bytes < MEGABITS) return @"0 Mb/s";
        else if (minUnit == 3 && bytes < GIGABITS) return @"0 Gb/s";

        if (bytes < KILOBITS) return [NSString stringWithFormat:@"%.0f b/s", (double)bytes];
        else if (bytes < MEGABITS) return [NSString stringWithFormat:@"%.0f Kb/s", (double)bytes / KILOBITS];
        else if (bytes < GIGABITS) return [NSString stringWithFormat:@"%.2f Mb/s", (double)bytes / MEGABITS];
        else return [NSString stringWithFormat:@"%.2f Gb/s", (double)bytes / GIGABITS];
    }
}

static NSAttributedString* formattedAttributedSpeedString(BOOL isUp, NSInteger speedIcon, NSInteger minUnit, BOOL hideWhenZero, double fontSize)
{
    @autoreleasepool {
        if (!attributedUploadPrefix)
            attributedUploadPrefix = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"▲"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedDownloadPrefix)
            attributedDownloadPrefix = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"▼"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedUploadPrefix2)
            attributedUploadPrefix2 = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"↑"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        if (!attributedDownloadPrefix2)
            attributedDownloadPrefix2 = [[NSAttributedString alloc] initWithString:[[NSString stringWithUTF8String:"↓"] stringByAppendingString:@" "] attributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize]}];
        
        NSMutableAttributedString* mutableString = [[NSMutableAttributedString alloc] init];
        
        UpDownBytes upDownBytes = getUpDownBytes();
        
        uint64_t diff;
        
        if (isUp) {
            if (upDownBytes.outputBytes > prevOutputBytes)
                diff = upDownBytes.outputBytes - prevOutputBytes;
            else
                diff = 0;
            prevOutputBytes = upDownBytes.outputBytes;
        } else {
            if (upDownBytes.inputBytes > prevInputBytes)
                diff = upDownBytes.inputBytes - prevInputBytes;
            else
                diff = 0;
            prevInputBytes = upDownBytes.inputBytes;
        }
        
        if (DATAUNIT == 1)
            diff *= 8;
        
        NSString *speedString = formattedSpeed(diff, minUnit);
        if (!hideWhenZero || ![speedString hasPrefix:@"0"]) {
            if (isUp)
                [mutableString appendAttributedString:(speedIcon == 0 ? attributedUploadPrefix : attributedUploadPrefix2)];
            else
                [mutableString appendAttributedString:(speedIcon == 0 ? attributedDownloadPrefix : attributedDownloadPrefix2)];
            [mutableString appendAttributedString:[[NSAttributedString alloc] initWithString:speedString]];
        }
        
        return [mutableString copy];
    }
}

#pragma mark - Battery Temp Widget
NSDictionary* getBatteryInfo()
{
    CFDictionaryRef matching = IOServiceMatching("IOPMPowerSource");
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, matching);
    CFMutableDictionaryRef prop = NULL;
    IORegistryEntryCreateCFProperties(service, &prop, NULL, 0);
    NSDictionary* dict = (__bridge_transfer NSDictionary*)prop;
    IOObjectRelease(service);
    return dict;
}

static NSString* formattedTemp(BOOL useFahrenheit)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        // AdapterDetails.Watts.Description.Temperature
        double temp = [batteryInfo[@"Temperature"] doubleValue] / 100.0;
        if (temp) {
            if (useFahrenheit) {
                temp = (temp * 9.0/5.0) + 32;
                return [NSString stringWithFormat: @"%.2fºF", temp];
            } else {
                return [NSString stringWithFormat: @"%.2fºC", temp];
            }
        }
    }
    return @"??ºC";
}

#pragma mark - CPU Temp Widget (IOReport)
/*
 CPU/SoC die temperature is not exposed by any public API. It is published on the
 IOReport "CPU Die Temperature" channel group instead. IOReport lives inside
 IOKit.framework but its symbols are private, so they are resolved at runtime with
 dlopen/dlsym: if anything is unavailable the widget degrades to "??" instead of
 crashing the HUD.

 Entitlements required: com.apple.private.security.no-sandbox (already present in
 ent.plist). Without it IOReport returns nothing on jailed devices.
 */
#import <dlfcn.h>
#import <math.h>

typedef void *IORepSubRef;
typedef CFMutableDictionaryRef (*fn_IOReportCopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef CFMutableDictionaryRef (*fn_IOReportCopyAllChannels)(uint64_t, uint64_t);
typedef IORepSubRef (*fn_IOReportCreateSubscription)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*fn_IOReportCreateSamples)(IORepSubRef, CFMutableDictionaryRef, CFTypeRef);
typedef long (*fn_IOReportSimpleGetIntegerValue)(CFDictionaryRef, int);
typedef CFStringRef (*fn_IOReportChannelGetChannelName)(CFDictionaryRef);

static BOOL ioReportResolved = NO;
static fn_IOReportCopyChannelsInGroup pCopyChannelsInGroup = NULL;
static fn_IOReportCopyAllChannels pCopyAllChannels = NULL;
static fn_IOReportCreateSubscription pCreateSubscription = NULL;
static fn_IOReportCreateSamples pCreateSamples = NULL;
static fn_IOReportSimpleGetIntegerValue pSimpleGetIntegerValue = NULL;
static fn_IOReportChannelGetChannelName pChannelGetChannelName = NULL;

static int cpuTempRetryCountdown = 0;
static BOOL cpuTempSetupFailed = NO;

// How many times we are allowed to walk the candidate groups. Probing allocates
// an IOReport subscription per group and IOReport exposes no documented way to
// release one, so the budget keeps a permanently failing device from leaking
// a subscription every second.
static int cpuTempProbeBudget = 5;

// The group that worked, plus its subscription, reused on every later refresh.
static CFStringRef gActiveGroup = NULL;
static IORepSubRef gActiveSubscription = NULL;
static CFMutableDictionaryRef gActiveChannels = NULL;

// The HID sensor path cannot be cached like a subscription (the value is polled
// fresh each time), so remember that it works and read it directly afterwards
// instead of burning the probe budget on every refresh.
static BOOL gHIDWorks = NO;

#pragma mark - Temperature diagnostics

/* Builds a text report of every temperature source this device actually
   exposes. Shown in-app so the data can be read back without a debugger. */
static NSMutableString *gDiag = nil;
static BOOL gDiagDone = NO;

static double getCPUDieTemperature(void); // forward decl, run on demand

static void diagReset(void)
{
    @try {
        gDiagDone = NO;
        gDiag = [NSMutableString string];
        [gDiag appendString:@"=== Helium CPU Temperature Diagnostics ===\n"];
        [gDiag appendFormat:@"Device: %@ / iOS %@\n\n",
            [[UIDevice currentDevice] model], [[UIDevice currentDevice] systemVersion]];
    } @catch (NSException *e) { }
}

static void diagAdd(NSString *line)
{
    @try {
        if (!gDiag) return;
        [gDiag appendString:line];
        [gDiag appendString:@"\n"];
    } @catch (NSException *e) { }
}

// This file is compiled as Objective-C++ (WidgetManager.mm). Without an explicit
// C linkage the symbol gets name-mangled, and the plain Objective-C bridge
// (SwiftObjCPPBridger.m) then fails to link against it.
extern "C" NSString* HeliumTemperatureDiagnostics(void)
{
    @try {
        // The HUD renders in a separate process, so its report is not visible here.
        // The main app carries the same entitlements, so it simply probes itself.
        if (!gDiagDone) {
            (void)getCPUDieTemperature();
        }

        NSString *text = [gDiag length] > 0 ? [gDiag copy] : @"(diagnostics produced no output)";

        // This build is unsandboxed, so the report is also written out for anyone
        // who prefers to fetch it with a file browser.
        for (NSString *p in @[@"/var/mobile/Documents/HeliumTempDiag.txt",
                              @"/var/mobile/Media/Downloads/HeliumTempDiag.txt"]) {
            @try {
                [text writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } @catch (NSException *e) { }
        }
        return text;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"diagnostics failed: %@", e.reason];
    }
}

// IOKit is already linked into the app (Makefile PRIVATE_FRAMEWORKS), so its
// symbols normally live in the default namespace and dlsym(RTLD_DEFAULT, …)
// finds them without any dlopen. Resolving via a dlopen()ed handle only — which
// is what this used to do — fails on devices where dlopen(IOKit) does not work.
static void *gIOKitHandle = NULL;
static BOOL gIOKitTried = NO;
static NSString *gIOKitOpenResult = nil;
static BOOL gDefaultNSWorked = NO;

static void *openIOKit(void)
{
    if (gIOKitTried) return gIOKitHandle;
    gIOKitTried = YES;

    gIOKitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (gIOKitHandle) {
        gIOKitOpenResult = @"dlopen(IOKit.framework) OK";
    } else {
        const char *err = dlerror();
        gIOKitOpenResult = [NSString stringWithFormat:@"dlopen(IOKit.framework) FAIL: %s",
                            err ? err : "?"];
        gIOKitHandle = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (gIOKitHandle) gIOKitOpenResult = @"dlopen(PrivateFrameworks/IOKit.framework) OK";
    }
    return gIOKitHandle;
}

static void *resolveSym(const char *name)
{
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) {
        gDefaultNSWorked = YES;
        return p;
    }
    void *h = openIOKit();
    return h ? dlsym(h, name) : NULL;
}

static BOOL ensureIOReportSymbols(void)
{
    if (ioReportResolved) {
        return (pCreateSamples != NULL && pSimpleGetIntegerValue != NULL);
    }
    ioReportResolved = YES;

    pCopyChannelsInGroup   = (fn_IOReportCopyChannelsInGroup)resolveSym("IOReportCopyChannelsInGroup");
    pCopyAllChannels       = (fn_IOReportCopyAllChannels)resolveSym("IOReportCopyAllChannels");
    pCreateSubscription    = (fn_IOReportCreateSubscription)resolveSym("IOReportCreateSubscription");
    pCreateSamples         = (fn_IOReportCreateSamples)resolveSym("IOReportCreateSamples");
    pSimpleGetIntegerValue = (fn_IOReportSimpleGetIntegerValue)resolveSym("IOReportSimpleGetIntegerValue");
    pChannelGetChannelName = (fn_IOReportChannelGetChannelName)resolveSym("IOReportChannelGetChannelName");
    return (pCreateSamples != NULL && pSimpleGetIntegerValue != NULL);
}

// forward declarations: the probe runs before these are defined
static double normalizeTemperature(long raw);
static BOOL findTemperatureInSamples(CFDictionaryRef node, long *outRaw, NSString **outName, int depth);
static BOOL ensureHIDSymbols(void);
static double readHIDSensorTemperature(NSString **outName, NSMutableArray *dumpOut);

// Probe ONE channel group end to end: copy its channels, subscribe to just those,
// sample once and look for a temperature reading.
//
// Subscribing to the *entire* channel set (IOReportCopyAllChannels) is what the
// previous implementation did as a fallback, and it is unreliable: on older SoCs
// the subscription is refused and the widget silently degraded to "??". Probing
// groups one at a time keeps each subscription small and tells us which group
// actually worked.
static BOOL tryTemperatureGroup(CFStringRef group, double *outC, NSString **outName, BOOL keep)
{
    if (!pCopyChannelsInGroup || !pCreateSubscription || !pCreateSamples) return NO;

    CFMutableDictionaryRef channels = pCopyChannelsInGroup(group, NULL, 0, 0, 0);
    if (!channels) return NO;
    if (CFDictionaryGetCount(channels) == 0) {
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

    // Only the channels actually subscribed to can be sampled.
    CFMutableDictionaryRef target = subbed ? subbed : channels;

    BOOL ok = NO;
    double c = NAN;
    NSString *hitName = nil;
    CFDictionaryRef samples = pCreateSamples(sub, target, NULL);
    if (samples) {
        long raw = 0;
        NSString *name = nil;
        if (findTemperatureInSamples(samples, &raw, &name, 0)) {
            c = normalizeTemperature(raw);
            if (!isnan(c)) {
                ok = YES;
                hitName = name;
            }
        }
        CFRelease(samples);
    }

    if (ok && keep) {
        // Keep this subscription alive and reuse it: IOReport has no documented
        // release, and CFRelease on it can crash the HUD.
        gActiveGroup = group;
        gActiveSubscription = sub;
        gActiveChannels = target;
        if (target != channels) {
            CFRelease(channels);
        }
    } else {
        // One-off probe (diagnostics). The channel set is released; the
        // subscription itself is intentionally left allocated (bounded count).
        CFRelease(channels);
        if (subbed) CFRelease(subbed);
    }
    if (ok) {
        if (outC) *outC = c;
        if (outName) *outName = hitName;
    }
    return ok;
}

// Rate how likely a channel name is a die temperature. Older SoCs do not always
// spell it "…Temperature", so TEMP / THERMAL / DIE / TDIE all count, while
// readings that are obviously power or voltage are rejected outright.
static int temperatureScore(NSString *name)
{
    if ([name length] == 0) return 0;
    NSString *u = [name uppercaseString];

    if ([u rangeOfString:@"POWER"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"ENERGY"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"VOLTAGE"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"CURRENT"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"COUNT"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"FREQ"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"RESIDENCY"].location != NSNotFound) return -1;

    int score = 0;
    if ([u rangeOfString:@"TEMPERATURE"].location != NSNotFound) score += 100;
    if ([u rangeOfString:@"TDIE"].location != NSNotFound) score += 60;
    if ([u rangeOfString:@"TEMP"].location != NSNotFound) score += 50;
    if ([u rangeOfString:@"THERMAL"].location != NSNotFound) score += 50;
    if ([u rangeOfString:@"DIE"].location != NSNotFound) score += 40;
    if ([u rangeOfString:@"CPU"].location != NSNotFound) score += 20;
    if ([u rangeOfString:@"SOC"].location != NSNotFound) score += 15;
    if ([u rangeOfString:@"GPU"].location != NSNotFound) score += 5;
    return score;
}

// Walk the nested sample dictionary (group -> subgroup -> channel) and return the
// best-scoring channel whose value normalises to a plausible SoC temperature.
static BOOL findTemperatureInSamples(CFDictionaryRef node, long *outRaw, NSString **outName, int depth)
{
    if (!node || CFGetTypeID(node) != CFDictionaryGetTypeID()) return NO;
    if (!pSimpleGetIntegerValue) return NO;
    if (depth > 6) return NO;

    CFIndex count = CFDictionaryGetCount(node);
    if (count <= 0 || count > 8192) return NO;

    CFTypeRef *keys = (CFTypeRef *)malloc(sizeof(CFTypeRef) * (size_t)count);
    CFTypeRef *vals = (CFTypeRef *)malloc(sizeof(CFTypeRef) * (size_t)count);
    if (!keys || !vals) {
        free(keys);
        free(vals);
        return NO;
    }
    CFDictionaryGetKeysAndValues(node, keys, vals);

    int bestScore = 0;
    long bestRaw = 0;
    NSString *bestName = nil;

    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef key = keys[i];
        CFTypeRef val = vals[i];

        NSString *name = nil;
        if (key && CFGetTypeID(key) == CFStringGetTypeID()) {
            name = (__bridge NSString *)key;
        } else if (val && CFGetTypeID(val) == CFDictionaryGetTypeID() && pChannelGetChannelName) {
            CFStringRef n = pChannelGetChannelName((CFDictionaryRef)val);
            if (n) name = (__bridge NSString *)n;
        }

        if (name && val && CFGetTypeID(val) == CFDictionaryGetTypeID()) {
            int score = temperatureScore(name);
            if (score > 0) {
                long v = pSimpleGetIntegerValue((CFDictionaryRef)val, 0);
                if (!isnan(normalizeTemperature(v)) && score > bestScore) {
                    bestScore = score;
                    bestRaw = v;
                    bestName = name;
                }
            }
        }

        if (val && CFGetTypeID(val) == CFDictionaryGetTypeID()) {
            long r = 0;
            NSString *n2 = nil;
            if (findTemperatureInSamples((CFDictionaryRef)val, &r, &n2, depth + 1)) {
                int s2 = n2 ? temperatureScore(n2) : 0;
                if (s2 > bestScore) {
                    bestScore = s2;
                    bestRaw = r;
                    bestName = n2;
                }
            }
        }
    }

    free(keys);
    free(vals);

    if (bestScore > 0) {
        if (outRaw) *outRaw = bestRaw;
        if (outName) *outName = bestName ?: @"";
        return YES;
    }
    return NO;
}

// IOReport publishes temperatures in different scales depending on the channel:
// plain Celsius, decidegrees (1/10 C) or centidegrees (1/100 C). Pick the scale
// that lands inside a plausible range for a phone SoC.
static double normalizeTemperature(long raw)
{
    double d = (double)raw;
    if (d >= -50.0 && d <= 150.0) return d;
    if (d / 10.0 >= -50.0 && d / 10.0 <= 150.0) return d / 10.0;
    if (d / 100.0 >= -50.0 && d / 100.0 <= 150.0) return d / 100.0;
    return NAN;
}

// Channel groups that carry a die temperature on at least one SoC/iOS pair.
// Probed in order; the first one yielding a plausible reading wins.
static CFStringRef kTemperatureGroups[] = {
    CFSTR("CPU Die Temperature"),
    CFSTR("SoC Die Temperature"),
    CFSTR("GPU Die Temperature"),
    CFSTR("Thermal"),
    CFSTR("Energy Model"),
    CFSTR("PLATFORM Power"),
    CFSTR("PMP"),
    CFSTR("DieTemp"),
    CFSTR("temperature"),
    CFSTR("CPU Die Temperature (C)"),
    CFSTR("SoC Die Temperature (C)"),
};
static const int kTemperatureGroupCount =
    (int)(sizeof(kTemperatureGroups) / sizeof(kTemperatureGroups[0]));

// Returns the CPU/SoC die temperature in Celsius, or NAN when unavailable.
static double getCPUDieTemperature(void)
{
    // 0) Fast path: the HID sensors already proved to work. Re-reading them is
    //    cheap and does not consume the probe budget.
    if (gHIDWorks && ensureHIDSymbols()) {
        NSString *n = nil;
        double t = readHIDSensorTemperature(&n, nil);
        if (!isnan(t)) return t;
        gHIDWorks = NO; // stopped reporting; fall through and probe again
    }

    // 1) Fast path: reuse the subscription that already proved to work.
    if (gActiveSubscription && pCreateSamples) {
        CFDictionaryRef samples = pCreateSamples(gActiveSubscription, gActiveChannels, NULL);
        if (samples) {
            long raw = 0;
            NSString *name = nil;
            BOOL ok = findTemperatureInSamples(samples, &raw, &name, 0);
            CFRelease(samples);
            if (ok) {
                double c = normalizeTemperature(raw);
                if (!isnan(c)) {
                    cpuTempSetupFailed = NO;
                    return c;
                }
            }
        }
        // the cached group stopped reporting -> probe again below
        gActiveSubscription = NULL;
        gActiveChannels = NULL;
        gActiveGroup = NULL;
    }

    // 2) Respect the probe budget and the backoff between attempts.
    if (cpuTempProbeBudget <= 0) return NAN;
    if (cpuTempRetryCountdown > 0) {
        cpuTempRetryCountdown--;
        return NAN;
    }
    cpuTempProbeBudget--;

    // 3) The first run records everything it finds, later ones stop at the hit.
    BOOL fullScan = !gDiagDone;
    if (fullScan) diagReset();

    // ---- Source 1: HID thermal sensors (widest device coverage) ----
    // IOReport does not even resolve on some SoCs (iPhone X / A11), so try the HID
    // sensors first: they are what the system's own thermal monitor reads.
    BOOL hidOK = ensureHIDSymbols();
    double hidTemp = NAN;
    NSString *hidName = nil;
    if (fullScan) {
        diagAdd([NSString stringWithFormat:
            @"[0] HID symbols: %@   (default-namespace hit=%d, %@)",
            hidOK ? @"OK" : @"MISSING", gDefaultNSWorked, gIOKitOpenResult ?: @"n/a"]);
    }
    if (hidOK) {
        NSMutableArray *dump = fullScan ? [NSMutableArray array] : nil;
        hidTemp = readHIDSensorTemperature(&hidName, dump);
        if (fullScan) {
            diagAdd([NSString stringWithFormat:@"[1] HID matched sensors: %lu",
                     (unsigned long)[dump count]]);
            for (NSString *line in dump) diagAdd(line);
            diagAdd(!isnan(hidTemp)
                ? [NSString stringWithFormat:@"[1] HID best: %@ = %.2fC", hidName ?: @"?", hidTemp]
                : @"[1] HID best: none");
        }
    }

    // ---- Source 2: IOReport ----
    BOOL ioOK = ensureIOReportSymbols();
    if (fullScan) {
        diagAdd([NSString stringWithFormat:
            @"[2] IOReport symbols: %@   channels=%d all=%d subscribe=%d sample=%d getint=%d",
            ioOK ? @"OK" : @"MISSING",
            pCopyChannelsInGroup != NULL, pCopyAllChannels != NULL,
            pCreateSubscription != NULL, pCreateSamples != NULL,
            pSimpleGetIntegerValue != NULL]);
    }

    double result = hidTemp;
    NSString *hitName = hidName;

    for (int i = 0; i < kTemperatureGroupCount && (fullScan || isnan(result)) && ioOK; i++) {
        double c = NAN;
        NSString *name = nil;
        NSString *gname = (__bridge NSString *)kTemperatureGroups[i];
        // Only the first hit is cached; extra probes during a scan are one-off.
        BOOL ok = tryTemperatureGroup(kTemperatureGroups[i], &c, &name, isnan(result));

        if (fullScan) {
            if (ok) {
                diagAdd([NSString stringWithFormat:
                    @"[2] \"%@\" -> HIT   %@   %.2fC", gname, name, c]);
            } else {
                diagAdd([NSString stringWithFormat:
                    @"[2] \"%@\" -> empty / no temperature channel", gname]);
            }
        }
        if (ok && isnan(result)) {
            result = c;
            hitName = name;
        }
    }

    // 4) Last resort: enumerate every group name the device reports and probe the
    //    ones that look thermal, in case the fixed list above misses it.
    if (ioOK && isnan(result) && pCopyAllChannels) {
        CFMutableDictionaryRef all = pCopyAllChannels(0, 0);
        if (all) {
            CFIndex count = CFDictionaryGetCount(all);
            if (fullScan) {
                diagAdd([NSString stringWithFormat:@"[3] all-channels groups: %ld", (long)count]);
            }
            if (count > 0 && count < 8192) {
                CFTypeRef *keys = (CFTypeRef *)malloc(sizeof(CFTypeRef) * (size_t)count);
                CFTypeRef *vals = (CFTypeRef *)malloc(sizeof(CFTypeRef) * (size_t)count);
                if (keys && vals) {
                    CFDictionaryGetKeysAndValues((CFDictionaryRef)all, keys, vals);
                    for (CFIndex i = 0; i < count && isnan(result); i++) {
                        CFTypeRef k = keys[i];
                        if (!k || CFGetTypeID(k) != CFStringGetTypeID()) continue;
                        NSString *gname = (__bridge NSString *)k;
                        NSString *u = [gname uppercaseString];
                        if ([u rangeOfString:@"TEMP"].location == NSNotFound &&
                            [u rangeOfString:@"THERM"].location == NSNotFound &&
                            [u rangeOfString:@"DIE"].location == NSNotFound &&
                            [u rangeOfString:@"CPU"].location == NSNotFound &&
                            [u rangeOfString:@"SOC"].location == NSNotFound) {
                            continue;
                        }
                        double c = NAN;
                        NSString *name = nil;
                        if (tryTemperatureGroup((CFStringRef)k, &c, &name, isnan(result))) {
                            if (fullScan) {
                                diagAdd([NSString stringWithFormat:
                                    @"[3] scan \"%@\" -> HIT   %@   %.2fC", gname, name, c]);
                            }
                            if (isnan(result)) {
                                result = c;
                                hitName = name;
                            }
                        }
                    }
                }
                free(keys);
                free(vals);
            }
            CFRelease(all);
        }
    }

    if (!isnan(hidTemp)) gHIDWorks = YES;

    if (fullScan) {
        diagAdd(@"");
        if (!isnan(result)) {
            diagAdd([NSString stringWithFormat:@"[4] RESULT: %.2f C   source: %@", result, hitName ?: @"?"]);
        } else {
            diagAdd(@"[4] RESULT: no CPU/SoC temperature source found on this device");
        }
        gDiagDone = YES;
    }

    if (isnan(result)) {
        cpuTempSetupFailed = YES;
        cpuTempRetryCountdown = 30;
    } else {
        cpuTempSetupFailed = NO;
    }
    return result;
}

#pragma mark - CPU Temp Widget (HID sensors)

/*
 The HID event system exposes the SoC thermal sensors directly and works on a far
 wider range of hardware than IOReport (which does not even resolve on iPhone X /
 A11). Match the AppleVendor temperature-sensor usage and read each service's
 temperature event.

 On iPhone the sensors are named like "PMU tdie1" (CPU die), "PMU tdev1" (device)
 and "gas gauge battery"; die sensors are preferred.
 */
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;

typedef IOHIDEventSystemClientRef (*fn_IOHIDEventSystemClientCreate)(CFAllocatorRef);
typedef int (*fn_IOHIDEventSystemClientSetMatching)(IOHIDEventSystemClientRef, CFDictionaryRef);
typedef CFArrayRef (*fn_IOHIDEventSystemClientCopyServices)(IOHIDEventSystemClientRef);
typedef CFTypeRef (*fn_IOHIDServiceClientCopyProperty)(IOHIDServiceClientRef, CFStringRef);
typedef IOHIDEventRef (*fn_IOHIDServiceClientCopyEvent)(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
typedef IOHIDFloat (*fn_IOHIDEventGetFloatValue)(IOHIDEventRef, int32_t);

#define HELIUM_HID_EVENT_TEMPERATURE 15
#define HELIUM_HID_FIELD_BASE(t)     ((t) << 16)
#define HELIUM_APPLE_VENDOR_PAGE     0xff00
#define HELIUM_APPLE_TEMP_SENSOR     0x0005

static fn_IOHIDEventSystemClientCreate       pHIDCreate       = NULL;
static fn_IOHIDEventSystemClientSetMatching  pHIDSetMatching  = NULL;
static fn_IOHIDEventSystemClientCopyServices pHIDCopyServices = NULL;
static fn_IOHIDServiceClientCopyProperty     pHIDCopyProperty = NULL;
static fn_IOHIDServiceClientCopyEvent        pHIDCopyEvent    = NULL;
static fn_IOHIDEventGetFloatValue            pHIDGetFloat     = NULL;
static BOOL hidResolved = NO;

static BOOL ensureHIDSymbols(void)
{
    if (!hidResolved) {
        hidResolved = YES;
        pHIDCreate       = (fn_IOHIDEventSystemClientCreate)resolveSym("IOHIDEventSystemClientCreate");
        pHIDSetMatching  = (fn_IOHIDEventSystemClientSetMatching)resolveSym("IOHIDEventSystemClientSetMatching");
        pHIDCopyServices = (fn_IOHIDEventSystemClientCopyServices)resolveSym("IOHIDEventSystemClientCopyServices");
        pHIDCopyProperty = (fn_IOHIDServiceClientCopyProperty)resolveSym("IOHIDServiceClientCopyProperty");
        pHIDCopyEvent    = (fn_IOHIDServiceClientCopyEvent)resolveSym("IOHIDServiceClientCopyEvent");
        pHIDGetFloat     = (fn_IOHIDEventGetFloatValue)resolveSym("IOHIDEventGetFloatValue");
    }
    return (pHIDCreate && pHIDSetMatching && pHIDCopyServices && pHIDCopyEvent && pHIDGetFloat);
}

// Die sensors are preferred; battery / charger gauges are rejected outright.
static int hidSensorScore(NSString *name)
{
    if ([name length] == 0) return 0;
    NSString *u = [name uppercaseString];
    if ([u rangeOfString:@"GAUGE"].location != NSNotFound)   return -1;
    if ([u rangeOfString:@"BATTERY"].location != NSNotFound) return -1;
    if ([u rangeOfString:@"CHARGER"].location != NSNotFound) return -1;

    int score = 1;
    if ([u rangeOfString:@"TDIE"].location != NSNotFound) score += 100;
    if ([u rangeOfString:@"CPU"].location  != NSNotFound) score += 60;
    if ([u rangeOfString:@"SOC"].location  != NSNotFound) score += 50;
    if ([u rangeOfString:@"PMU"].location  != NSNotFound) score += 30;
    if ([u rangeOfString:@"TDEV"].location != NSNotFound) score += 10;
    return score;
}

// Polls every matched thermal sensor once. Returns the best candidate, and when
// dumpOut is given also records every sensor seen (for the diagnostics report).
static double readHIDSensorTemperature(NSString **outName, NSMutableArray *dumpOut)
{
    if (!ensureHIDSymbols()) return NAN;

    NSDictionary *query = @{
        @"PrimaryUsagePage": @(HELIUM_APPLE_VENDOR_PAGE),
        @"PrimaryUsage": @(HELIUM_APPLE_TEMP_SENSOR)
    };

    IOHIDEventSystemClientRef system = pHIDCreate(kCFAllocatorDefault);
    if (!system) return NAN;

    pHIDSetMatching(system, (__bridge CFDictionaryRef)query);
    CFArrayRef services = pHIDCopyServices(system);
    if (!services) {
        CFRelease(system);
        return NAN;
    }

    double best = NAN;
    int bestScore = 0;
    NSString *bestName = nil;
    CFIndex count = CFArrayGetCount(services);

    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (!svc) continue;

        NSString *product = nil;
        if (pHIDCopyProperty) {
            CFTypeRef p = pHIDCopyProperty(svc, CFSTR("Product"));
            if (p) product = (__bridge_transfer NSString *)p;
        }

        IOHIDEventRef event = pHIDCopyEvent(svc, HELIUM_HID_EVENT_TEMPERATURE, 0, 0);
        if (!event) continue;
        double t = pHIDGetFloat(event, HELIUM_HID_FIELD_BASE(HELIUM_HID_EVENT_TEMPERATURE));
        CFRelease(event);

        if (dumpOut) {
            [dumpOut addObject:[NSString stringWithFormat:@"      %@ = %.2f",
                                product ?: @"(unnamed)", t]];
        }
        if (isnan(t) || t < -40.0 || t > 150.0) continue;

        int score = hidSensorScore(product);
        if (score > bestScore) {
            bestScore = score;
            best = t;
            bestName = product;
        }
    }

    CFRelease(services);
    CFRelease(system);

    if (outName) *outName = bestName;
    return best;
}

static NSString* formattedCPUTemp(BOOL useFahrenheit)
{
    double temp = getCPUDieTemperature();
    if (isnan(temp)) {
        return useFahrenheit ? @"??ºF" : @"??ºC";
    }
    if (useFahrenheit) {
        temp = (temp * 9.0/5.0) + 32.0;
        return [NSString stringWithFormat: @"%.2fºF", temp];
    }
    return [NSString stringWithFormat: @"%.2fºC", temp];
}

#pragma mark - CPU Usage / CPU Frequency Widgets

/*
 Both widgets report a number the kernel does not simply hand over, and both are
 built the same way: keep the state in a file-scope static, and make the formatter
 itself do as little work as possible.

   * CPU load is not a figure the kernel keeps for us. host_processor_info()
     returns *cumulative tick counters* per core, so a percentage only exists as
     the difference between two samples. Helium redraws on a timer and the
     formatter is otherwise a pure function, so the previous sample lives in a
     static — the same trick the network widget already uses for prevOutputBytes.

   * The clock has to be *measured* with a busy loop (see CPUFrequencyProbe.mm),
     which blocks for ~15-20 ms. That must never happen on the HUD's render path,
     so it is sampled on its own queue at a fixed cadence and the formatter only
     ever reads the cached value.

 Neither needs a new entitlement — host_processor_info and inline assembly are both
 open to a jailed app. (The CPU temperature widget next door does need no-sandbox,
 because IOReport does. The two are unrelated.)
 */

#import <mach/mach.h>
#import "CPUFrequencyProbe.h"

// MARK: - CPU load

// Per-core busy fraction from the previous sample, plus the tick counters it came
// from. Reused across redraws so two CPU widgets in one set share a measurement
// instead of eating each other's delta.
static double *gCPUFractions = NULL;
static natural_t gCPUFractionCount = 0;
static CFAbsoluteTime gCPUFractionsStamp = 0;
static BOOL gCPUFractionsValid = NO;

// How long a computed sample stays usable. Longer than any single redraw, far
// shorter than the widget's own update interval (1 s by default), so every redraw
// still gets a fresh measurement.
#define CPU_USAGE_CACHE_SECONDS 0.25

static uint64_t *gPrevCPUTicks = NULL;
static natural_t gPrevCPUTickCount = 0;

/// Snapshot the per-core tick counters. The caller owns `*outTicks`.
static BOOL copyCPUTicks(uint64_t **outTicks, natural_t *outCount)
{
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;
    natural_t cpuCount = 0;

    kern_return_t kr = host_processor_info(mach_host_self(),
                                           PROCESSOR_CPU_LOAD_INFO,
                                           &cpuCount,
                                           &info,
                                           &infoCount);
    if (kr != KERN_SUCCESS || info == NULL || cpuCount == 0) {
        return NO;
    }

    const natural_t states = CPU_STATE_MAX;
    // Casts are needed because this file is Objective-C++: in C a void* converts
    // implicitly, in C++ it does not.
    uint64_t *ticks = (uint64_t *)malloc(sizeof(uint64_t) * cpuCount * states);
    if (ticks != NULL) {
        for (natural_t core = 0; core < cpuCount; core++) {
            for (natural_t state = 0; state < states; state++) {
                ticks[core * states + state] = (uint64_t)info[core * states + state];
            }
        }
        *outTicks = ticks;
        *outCount = cpuCount;
    }

    // host_processor_info hands back a vm_allocate()d array. Not freeing it leaks a
    // page on every call, and this runs once per redraw.
    vm_deallocate(mach_task_self(),
                  (vm_address_t)info,
                  (vm_size_t)(infoCount * sizeof(integer_t)));

    return ticks != NULL;
}

/// Per-core busy fractions, memoised for `CPU_USAGE_CACHE_SECONDS`.
///
/// `*outFractions` points at the cache — the caller must **not** free it. Returns
/// NO while there is still no baseline to subtract (the first sample after launch,
/// or after the core count changed), which is what makes the widget show "--" once
/// rather than a fabricated 0 %.
static BOOL cpuBusyFractions(double **outFractions, natural_t *outCount)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if ((now - gCPUFractionsStamp) < CPU_USAGE_CACHE_SECONDS) {
        *outFractions = gCPUFractions;
        *outCount = gCPUFractionCount;
        return gCPUFractionsValid;
    }

    uint64_t *ticks = NULL;
    natural_t count = 0;
    if (!copyCPUTicks(&ticks, &count)) {
        gCPUFractionsStamp = now;
        gCPUFractionsValid = NO;
        return NO;
    }

    // No usable baseline yet: keep this snapshot and report "no reading". The
    // negative result is cached too, so every widget in the same redraw agrees.
    if (gPrevCPUTicks == NULL || gPrevCPUTickCount != count) {
        free(gPrevCPUTicks);
        gPrevCPUTicks = ticks;
        gPrevCPUTickCount = count;
        gCPUFractionsStamp = now;
        gCPUFractionsValid = NO;
        return NO;
    }

    const natural_t states = CPU_STATE_MAX;
    double *fractions = (double *)malloc(sizeof(double) * count);
    if (fractions == NULL) {
        free(ticks);
        gCPUFractionsStamp = now;
        gCPUFractionsValid = NO;
        return NO;
    }

    for (natural_t core = 0; core < count; core++) {
        uint64_t busy = 0;
        uint64_t total = 0;
        for (natural_t state = 0; state < states; state++) {
            uint64_t nowTicks = ticks[core * states + state];
            uint64_t beforeTicks = gPrevCPUTicks[core * states + state];
            uint64_t delta = nowTicks >= beforeTicks ? nowTicks - beforeTicks : 0;
            total += delta;
            if (state != CPU_STATE_IDLE) {
                busy += delta;
            }
        }
        fractions[core] = total == 0 ? 0.0 : (double)busy / (double)total;
    }

    free(gPrevCPUTicks);
    gPrevCPUTicks = ticks;
    gPrevCPUTickCount = count;

    free(gCPUFractions);
    gCPUFractions = fractions;
    gCPUFractionCount = count;
    gCPUFractionsStamp = CFAbsoluteTimeGetCurrent();
    gCPUFractionsValid = YES;

    *outFractions = gCPUFractions;
    *outCount = gCPUFractionCount;
    return YES;
}

/// Per-core busy fractions from the shared file — the SAME value SysProbe reads.
/// Returns nil when the file is missing or stale (> 5 s), so the caller can fall
/// back to its own host_processor_info delta.
///
/// Reading the shared file here (rather than recomputing locally) is what makes the
/// two apps show the same number: the publisher's tick and this widget's redraw are
/// not phase-locked, so two independent local computations would drift apart even
/// though both come from the same kernel counters.
static NSArray<NSNumber *> *heliumSharedCPUPerCore(void)
{
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSString *path in @[ @"/var/tmp/cpu_metrics.json",
                              @"/var/mobile/Library/Caches/cpu_metrics.json" ]) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *tsNum = j[@"ts"];
        if (!tsNum) continue;
        if (!((now - [tsNum doubleValue]) < 5.0)) continue;
        NSArray<NSNumber *> *pc = j[@"per_core"];
        if ([pc isKindOfClass:[NSArray class]] && pc.count > 0) return pc;
        NSNumber *u = j[@"usage"];
        if ([u isKindOfClass:[NSNumber class]]) return @[ u ];
    }
    return nil;
}

/// `mode`: 0 = average across cores, 1 = busiest core.
static NSString* formattedCPUUsage(NSInteger mode, BOOL showPercentage, NSInteger decimals)
{
    double value = 0.0;
    BOOL haveValue = NO;

    // Prefer the shared file (the value SysProbe renders) so the two apps agree.
    NSArray<NSNumber *> *sharedPerCore = heliumSharedCPUPerCore();
    if (sharedPerCore.count > 0) {
        if (mode == 1) {
            for (NSNumber *n in sharedPerCore) {
                if (n.doubleValue > value) value = n.doubleValue;
            }
        } else {
            for (NSNumber *n in sharedPerCore) {
                value += n.doubleValue;
            }
            value /= (double)sharedPerCore.count;
        }
        haveValue = YES;
    }

    if (!haveValue) {
        // Fall back to the local host_processor_info delta only when the file is
        // missing/stale (no publisher running).
        double *fractions = NULL;
        natural_t count = 0;
        if (!cpuBusyFractions(&fractions, &count) || fractions == NULL || count == 0) {
            return @"--";
        }
        if (mode == 1) {
            for (natural_t i = 0; i < count; i++) {
                if (fractions[i] > value) {
                    value = fractions[i];
                }
            }
        } else {
            for (natural_t i = 0; i < count; i++) {
                value += fractions[i];
            }
            value /= (double)count;
        }
    }

    // A tick counter that wrapped, or a core that came online mid-sample, can push
    // the ratio a hair outside [0, 1].
    if (value < 0.0) value = 0.0;
    if (value > 1.0) value = 1.0;

    NSString *number = [NSString stringWithFormat:(decimals == 1 ? @"%.1f" : @"%.0f"),
                        value * 100.0];
    return showPercentage ? [number stringByAppendingString:@"%"] : number;
}

// MARK: - CPU frequency

// The formatter reads the shared file (written by CPUMetricsPublisher at 1 Hz,
// IOReport-sourced when the HUD is root) as its primary source, so it matches
// SysProbe step-for-step. The local probe below is only the cold-start fallback.
//
// kHz; 0 means "no usable reading yet". An integer rather than a double so the
// sampling queue and the render path can share it without a lock — a naturally
// aligned 64-bit load/store is atomic on arm64, and this is only ever a hint for a
// status-bar readout, so a stale value on a torn read would not matter anyway.
static uint64_t gCPUFrequencyKHz = 0;
static CFAbsoluteTime gCPUFrequencyStamp = 0;
static BOOL gCPUFrequencySampling = NO;

// How long a measured clock stays usable.
//
// Two reasons this is seconds rather than "every redraw". The obvious one is cost:
// the probe is a ~15-20 ms full-speed busy loop, so running it per second would
// spend about 2 % of a performance core forever.
//
// The other one is that the probe would be measuring its own effect. It raises the
// clock on the core it lands on in order to read a meaningful number, so sampling
// it every second would keep the CPU boosted — the widget would be causing part of
// the load it reports, and the battery cost of a status-bar readout would be real.
// Between samples the readout repeats the last measurement, which is what every
// other monitor does too.
#define CPU_FREQUENCY_SAMPLE_SECONDS 3.0

static dispatch_queue_t cpuFrequencyQueue(void)
{
    static dispatch_once_t once;
    static dispatch_queue_t queue = NULL;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.leemin.helium.cpufreq", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

/// Kick off a measurement if the cached one has gone stale. Returns immediately.
static void cpuFrequencyScheduleIfStale(void)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // Throttled on time alone, success or failure: on a device where the probe
    // cannot produce a plausible number, keying off "do we have a value" would burn
    // a 20 ms busy loop on every single redraw.
    if (gCPUFrequencySampling || (now - gCPUFrequencyStamp) < CPU_FREQUENCY_SAMPLE_SECONDS) {
        return;
    }

    gCPUFrequencySampling = YES;
    dispatch_async(cpuFrequencyQueue(), ^{
        uint64_t megahertz = helium_measure_cpu_frequency_mhz();
        gCPUFrequencyKHz = megahertz * 1000ull;   // 0 on failure; retried in 3 s
        gCPUFrequencyStamp = CFAbsoluteTimeGetCurrent();
        gCPUFrequencySampling = NO;
    });
}

/// `unit`: 0 = GHz, 1 = MHz.
///
/// **Source: the shared file written by CPUMetricsPublisher at 1 Hz.**
///
/// The publisher (in this same HUD process) samples once a second and, when the
/// HUD is running as root, sources the clock from IOReport's real DVFS residency —
/// the actual current frequency step, not the peak a busy loop can coax out of the
/// core. That is also the exact figure SysProbe renders, so the two readouts step
/// together at 1 Hz instead of drifting. We read that file here rather than keeping
/// our own 3 s probe, so the widget and SysProbe can never disagree on frequency.
///
/// The local busy-loop probe (`gCPUFrequencyKHz`) survives only as a fallback for
/// the first half-second after launch (the publisher's first write lands ~0.5 s
/// in) or if the shared file is ever missing or stale. It is no longer the primary
/// path, so it can no longer keep the core boosted just to feed a status-bar number.
static uint64_t heliumSharedCPUFrequencyMHz(void)
{
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    uint64_t best = 0;
    for (NSString *path in @[ @"/var/tmp/cpu_metrics.json",
                              @"/var/mobile/Library/Caches/cpu_metrics.json" ]) {
        // The shared file is JSON (NSJSONSerialization), not a plist — so
        // dictionaryWithContentsOfFile: would return nil. Parse it as JSON.
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        NSError *err = nil;
        NSDictionary *prev = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![prev isKindOfClass:[NSDictionary class]]) continue;
        NSNumber *fmNum = prev[@"freq_mhz"];
        NSNumber *tsNum = prev[@"ts"];
        if (!fmNum || !tsNum) continue;
        uint64_t fm = [fmNum unsignedLongLongValue];
        NSTimeInterval t = [tsNum doubleValue];
        // 5 s freshness to match the publisher's own preserve-window; pick the
        // freshest file that actually carries a reading.
        if (fm > 0 && (now - t) < 5.0 && fm > best) {
            best = fm;
        }
    }
    return best;
}

static NSString* formattedCPUFrequency(NSInteger unit)
{
    uint64_t khz = 0;
    uint64_t sharedMHz = heliumSharedCPUFrequencyMHz();
    if (sharedMHz > 0) {
        // Primary: the 1 Hz shared-file value (IOReport when the HUD is root).
        khz = sharedMHz * 1000ull;
    } else {
        // Fallback: only while the shared file is missing/stale. Kick the local
        // probe so a cold start still resolves to a number after one redraw.
        cpuFrequencyScheduleIfStale();
        khz = gCPUFrequencyKHz;
    }

    if (khz == 0) {
        return @"--";
    }

    if (unit == 1) {
        return [NSString stringWithFormat:@"%llu MHz", khz / 1000ull];
    }
    return [NSString stringWithFormat:@"%.2f GHz", (double)khz / 1000000.0];
}

// MARK: - Shared-metrics accessors

/*
 The CPU readings above are file-scope statics, and CPUMetricsPublisher.mm lives in
 the same binary — so a plain C-linkage accessor is all the publisher needs. They
 deliberately return the *same* cached values the widgets render, so a second app
 reading the published file shows exactly what this HUD shows.

 `extern "C"` is required: this file is Objective-C++, and without it the symbols
 would be name-mangled and CPUMetricsPublisher.mm would fail to link.
*/

extern "C" double HeliumCPUUsageFraction(void)
{
    double *fractions = NULL;
    natural_t count = 0;
    if (!cpuBusyFractions(&fractions, &count) || fractions == NULL || count == 0) {
        return 0.0;
    }
    double sum = 0.0;
    for (natural_t i = 0; i < count; i++) {
        sum += fractions[i];
    }
    return sum / (double)count;
}

extern "C" NSArray<NSNumber *> *HeliumCPUPerCoreFractions(void)
{
    double *fractions = NULL;
    natural_t count = 0;
    if (!cpuBusyFractions(&fractions, &count) || fractions == NULL || count == 0) {
        return @[];
    }
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (natural_t i = 0; i < count; i++) {
        [result addObject:@(fractions[i])];
    }
    return result;
}

extern "C" uint64_t HeliumCPUFrequencyKHz(void)
{
    return gCPUFrequencyKHz;
}

extern "C" void HeliumCPUFrequencyKick(void)
{
    cpuFrequencyScheduleIfStale();
}

// MARK: - Cellular signal (RSRP)

/*
 Same shape as the CPU frequency widget above, and for the same reason: the
 reading comes from an XPC round-trip to CommCenter, which must never happen on
 the HUD's render path. A background queue samples every few seconds and the
 formatter only reads the cache.

 The difference from every other widget in this file is that this one can fail
 *silently* — see CellularSignalProbe.h. When CommCenter refuses the connection
 (missing `com.apple.CommCenter.fine-grained`), nothing throws and nothing is
 logged; the number just never arrives. So the probe records its own state and
 the widget's preferences screen surfaces it.
*/

#import "CellularSignalProbe.h"
#import "WiFiSignalProbe.h"

// dBm; 0 means "no reading yet". RSRP is always negative, so 0 is a safe
// sentinel and needs no separate flag.
static int32_t gSignalRSRPDbm = 0;
// Wi-Fi 那一侧。
static int32_t gWiFiRssiDbm = 0;
static BOOL gWiFiAssociated = NO;
static CFAbsoluteTime gWiFiStamp = 0;
static BOOL gWiFiSampling = NO;
// The slot the cached value came from. A widget configured for a different slot
// must not show it, so the cache is keyed on this and a mismatch reports
// "no reading" until the new sample lands.
static int32_t gSignalSlot = -1;
static CFAbsoluteTime gSignalStamp = 0;
static BOOL gSignalSampling = NO;

// How long a reading stays usable.
//
// Longer than the CPU clock's 3 s would be tempting — RSRP moves slowly — but
// this is the one number a user watches while walking around hunting for signal,
// and the call itself is sub-millisecond, so 3 s keeps it responsive without
// making the XPC traffic noticeable.
#define CELLULAR_SIGNAL_SAMPLE_SECONDS 3.0

static dispatch_queue_t cellularSignalQueue(void)
{
    static dispatch_once_t once;
    static dispatch_queue_t queue = NULL;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.leemin.helium.cellularsignal", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

/// Kick off a sample if the cache is stale (or belongs to another slot).
/// Returns immediately.
static void cellularSignalScheduleIfStale(int32_t slot)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gSignalSampling) {
        return;
    }
    if (slot == gSignalSlot && (now - gSignalStamp) < CELLULAR_SIGNAL_SAMPLE_SECONDS) {
        return;
    }

    gSignalSampling = YES;
    dispatch_async(cellularSignalQueue(), ^{
        int32_t value = helium_cellular_rsrp_dbm(slot);
        gSignalRSRPDbm = value;
        gSignalSlot = slot;
        gSignalStamp = CFAbsoluteTimeGetCurrent();
        gSignalSampling = NO;
    });
}

/// Wi-Fi 采样**单独一条队列**。
///
/// 与蜂窝分开：那边是 `CommCenter` 的 XPC，这边是 `wifid`，两条链互不相干。
/// 分开之后即使 Wi-Fi 那边卡住，蜂窝的采样照常，其他部件也不受影响。
static dispatch_queue_t wifiSignalQueue(void)
{
    static dispatch_once_t once;
    static dispatch_queue_t queue = NULL;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.leemin.helium.wifisignal", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void wifiSignalScheduleIfStale(void)
{
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (gWiFiSampling) {
        return;
    }
    if (gWiFiStamp != 0 && (now - gWiFiStamp) < CELLULAR_SIGNAL_SAMPLE_SECONDS) {
        return;
    }

    gWiFiSampling = YES;
    dispatch_async(wifiSignalQueue(), ^{
        // 先问「连没连」（`getifaddrs`，公开 API）。只有确实连着才去碰私有框架 ——
        // 不在 Wi-Fi 上时这个函数根本不进 MobileWiFi。
        BOOL associated = helium_wifi_is_associated();
        int32_t rssi = 0;
        if (associated) {
            // 内部带 latch：整个进程最多真正尝试一次。
            rssi = helium_wifi_rssi_dbm();
        }
        gWiFiAssociated = associated;
        gWiFiRssiDbm = rssi;
        gWiFiStamp = CFAbsoluteTimeGetCurrent();
        gWiFiSampling = NO;
    });
}

/// dBm 转成要显示的字符串。
static NSString* signalNumber(int32_t dbm, BOOL showUnit)
{
    NSString *number = [NSString stringWithFormat:@"%d", dbm];
    return showUnit ? [number stringByAppendingString:@" dBm"] : number;
}

/// `slot`: 0 follows the SIM the system is using for data, 1/2 pick explicitly.
/// `followNetwork`: 连着 Wi-Fi 且读到 RSSI 时改用 Wi-Fi 的数值。
static NSString* formattedCellularSignal(int32_t slot, BOOL showUnit, BOOL followNetwork)
{
    cellularSignalScheduleIfStale(slot);
    if (followNetwork) {
        wifiSignalScheduleIfStale();
    }

    // 连着 Wi-Fi **并且真的读到了 RSSI** 才切过去。
    //
    // 「关联了但读不到 RSSI」时不切换：那样会明明在 Wi-Fi 上却显示蜂窝数值。
    // 同时它也意味着 MobileWiFi 这条路走不通 —— 静默退化成原来的蜂窝小部件，
    // 比一直显示 `--` 有用。
    if (followNetwork && gWiFiAssociated && gWiFiRssiDbm < 0) {
        return signalNumber(gWiFiRssiDbm, showUnit);
    }

    // The cache is only valid for the slot it came from — otherwise switching
    // the widget from slot 1 to slot 2 would briefly show slot 1's signal.
    int32_t value = (slot == gSignalSlot) ? gSignalRSRPDbm : 0;
    if (value >= 0) {
        return @"--";
    }
    return signalNumber(value, showUnit);
}

/// State of the last probe, for the widget's preferences screen.
///
/// If nothing has been sampled yet, ask for one and report "pending" — the
/// caller is a settings screen, not the render path, so it can afford to wait
/// for the next redraw rather than block here.
extern "C" NSString* HeliumCellularSignalStatus(void)
{
    if (gSignalSlot < 0 && !gSignalSampling) {
        cellularSignalScheduleIfStale(0);
    }
    return [NSString stringWithUTF8String:helium_cellular_signal_state()];
}

/// 当前这一格显示的是哪一路信号，给设置页的状态行用。
///
/// 返回 `"wifi:<dBm>"` / `"wifi-failed:<原因>"` / `"cellular:<dBm>"` / `"unavailable"`。
///
/// **这一行是必要的，不是装饰**：Wi-Fi 与蜂窝的读数范围重叠（都在 -40…-100 之间），
/// 光看数字分不出是哪一路；而 MobileWiFi 那条路一旦读不到，这个部件会**静默地**
/// 退回蜂窝 —— 用户看到的是「信号一直不变」，看不出原因。
extern "C" NSString* HeliumSignalSource(void)
{
    // 设置页刚打开时可能一次都还没采过样（Wi-Fi 那边是异步的，而且只有 HUD 在画
    // 的时候才会被安排）。这里顺手安排一次 —— 不然下面会回落成「蜂窝」，
    // 而那是**错的**：用户明明在 Wi-Fi 上。
    if (gWiFiStamp == 0) {
        wifiSignalScheduleIfStale();
    }

    if (gWiFiAssociated && gWiFiRssiDbm < 0) {
        return [NSString stringWithFormat:@"wifi:%d", gWiFiRssiDbm];
    }
    if (gWiFiAssociated) {
        return [NSString stringWithFormat:@"wifi-failed:%s", helium_wifi_diagnosis()];
    }

    // Wi-Fi 那次采样还没落地。**如实说「还没好」，不要回落成「蜂窝」** ——
    // 之前就是这一步让「明明显示的是 Wi-Fi 数值、来源却写着蜂窝」。
    if (gWiFiStamp == 0) {
        return @"pending";
    }

    if (gSignalSlot >= 0 && gSignalRSRPDbm < 0) {
        return [NSString stringWithFormat:@"cellular:%d", gSignalRSRPDbm];
    }
    return @"unavailable";
}

#pragma mark - Battery Widget
/*
 Battery Widget Identifiers:
 0 = Watts
 1 = Charging Current
 2 = Regular Amperage
 3 = Charge Cycles
 */
static NSString* formattedBattery(NSInteger valueType)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        if (valueType == 0) {
            // Watts
            int watts = [batteryInfo[@"AdapterDetails"][@"Watts"] longLongValue];
            if (watts) {
                return [NSString stringWithFormat: @"%d W", watts];
            } else {
                return @"0 W";
            }
        } else if (valueType == 1) {
            // Charging Current
            double current = [batteryInfo[@"AdapterDetails"][@"Current"] doubleValue];
            if (current) {
                return [NSString stringWithFormat: @"%.0f mA", current];
            } else {
                return @"0 mA";
            }
        } else if (valueType == 2) {
            // Regular Amperage
            double amps = [batteryInfo[@"Amperage"] doubleValue];
            if (amps) {
                return [NSString stringWithFormat: @"%.0f mA", amps];
            } else {
                return @"0 mA";
            }
        } else if (valueType == 3) {
            // Charge Cycles
            return [batteryInfo[@"CycleCount"] stringValue];
        } else {
            return @"???";
        }
    }
    return @"??";
}

#pragma mark - Current Capacity Widget
static NSString* formattedCurrentCapacity(BOOL showPercentage)
{
    NSDictionary *batteryInfo = getBatteryInfo();
    if (batteryInfo) {
        return [
            NSString stringWithFormat: @"%@%@",
            [batteryInfo[@"CurrentCapacity"] stringValue],
            showPercentage ? @"%" : @""
            ];
    }
    return @"??%";
}

#pragma mark - Charging Symbol Widget
static NSString* formattedChargingSymbol(BOOL filled)
{
    [[UIDevice currentDevice] setBatteryMonitoringEnabled: YES];
    if ([[UIDevice currentDevice] batteryState] != UIDeviceBatteryStateUnplugged) {
        if (filled) {
            return @"bolt.fill";
        } else {
            return @"bolt";
        }
    }
    return @"";
}


#pragma mark - Main Widget Functions
/*
 Widget Identifiers:
 0 = None
 1 = Date
 2 = Network Up/Down
 3 = Device Temp
 4 = Battery Detail
 5 = Time
 6 = Text
 7 = Battery Percentage
 8 = Charging Symbol
 10 = CPU Temp (SoC die temperature via IOReport)

 TODO:
 - Music Visualizer
 */
void formatParsedInfo(NSDictionary *parsedInfo, NSInteger parsedID, NSMutableAttributedString *mutableString, double fontSize, UIColor *textColor, NSString *apiKey, NSString *dateLocale)
{
    NSString *widgetString;
    NSString *sfSymbolName;
    NSTextAttachment *imageAttachment;
    switch (parsedID) {
        case 1:
        case 5:
            // Date/Time
            widgetString = formattedDate(
                [parsedInfo valueForKey:@"dateFormat"] ? [parsedInfo valueForKey:@"dateFormat"] : (parsedID == 1 ? NSLocalizedString(@"E MMM dd", comment: @"") : @"hh:mm"), dateLocale
            );
            break;
        case 2:
            // Network Speed
            [
                mutableString appendAttributedString: formattedAttributedSpeedString(
                    [parsedInfo valueForKey:@"isUp"] ? [[parsedInfo valueForKey:@"isUp"] boolValue] : NO,
                    [parsedInfo valueForKey:@"speedIcon"] ? [[parsedInfo valueForKey:@"speedIcon"] intValue] : 0,
                    [parsedInfo valueForKey:@"minUnit"] ? [[parsedInfo valueForKey:@"minUnit"] intValue] : 1,
                    [parsedInfo valueForKey:@"hideSpeedWhenZero"] ? [[parsedInfo valueForKey:@"hideSpeedWhenZero"] boolValue] : NO,
                    fontSize
                )
            ];
            break;
        case 3:
            // Device Temp
            widgetString = formattedTemp(
                [parsedInfo valueForKey:@"useFahrenheit"] ? [[parsedInfo valueForKey:@"useFahrenheit"] boolValue] : NO
            );
            break;
        case 4:
            // Battery Stats
            widgetString = formattedBattery(
                [parsedInfo valueForKey:@"batteryValueType"] ? [[parsedInfo valueForKey:@"batteryValueType"] integerValue] : 0
            );
            break;
        case 6:
            // Text
            widgetString = [parsedInfo valueForKey:@"text"] ? [parsedInfo valueForKey:@"text"] : @"Unknown";
            break;
        case 7:
            // Current Capacity
            widgetString = formattedCurrentCapacity(
                [parsedInfo valueForKey:@"showPercentage"] ? [[parsedInfo valueForKey:@"showPercentage"] boolValue] : YES
            );
            break;
        case 8:
            // Charging Symbol
            sfSymbolName = formattedChargingSymbol(
                [parsedInfo valueForKey:@"filled"] ? [[parsedInfo valueForKey:@"filled"] boolValue] : YES
            );
            if (![sfSymbolName isEqualToString:@""]) {
                imageAttachment = [[NSTextAttachment alloc] init];
                imageAttachment.image = [
                    [
                        UIImage systemImageNamed:sfSymbolName
                        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:fontSize]
                    ]
                    imageWithTintColor:textColor
                ];
                [mutableString appendAttributedString:[NSAttributedString attributedStringWithAttachment:imageAttachment]];
            }
            break;
        case 10:
            // CPU Temp
            widgetString = formattedCPUTemp(
                [parsedInfo valueForKey:@"useFahrenheit"] ? [[parsedInfo valueForKey:@"useFahrenheit"] boolValue] : NO
            );
            break;
        case 11:
            // CPU Usage
            widgetString = formattedCPUUsage(
                [parsedInfo valueForKey:@"usageMode"] ? [[parsedInfo valueForKey:@"usageMode"] integerValue] : 0,
                [parsedInfo valueForKey:@"showPercentage"] ? [[parsedInfo valueForKey:@"showPercentage"] boolValue] : YES,
                [parsedInfo valueForKey:@"decimals"] ? [[parsedInfo valueForKey:@"decimals"] integerValue] : 0
            );
            break;
        case 12:
            // CPU Frequency
            widgetString = formattedCPUFrequency(
                [parsedInfo valueForKey:@"freqUnit"] ? [[parsedInfo valueForKey:@"freqUnit"] integerValue] : 0
            );
            break;
        case 13:
            // Signal: Wi-Fi RSSI when associated, cellular RSRP otherwise.
            widgetString = formattedCellularSignal(
                [parsedInfo valueForKey:@"signalSlot"] ? [[parsedInfo valueForKey:@"signalSlot"] intValue] : 0,
                [parsedInfo valueForKey:@"showUnit"] ? [[parsedInfo valueForKey:@"showUnit"] boolValue] : YES,
                // **默认关**：这条私有路还没在真机验证过，默认开启等于把它塞进每个人的 HUD。
                [parsedInfo valueForKey:@"followNetwork"] ? [[parsedInfo valueForKey:@"followNetwork"] boolValue] : NO
            );
            break;
        default:
            // do not add anything
            break;
    }
    if (widgetString) {
        widgetString = [widgetString stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        widgetString = [widgetString stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"];
        [
            mutableString appendAttributedString:[[NSAttributedString alloc] initWithString: widgetString]
        ];
    }
}

NSAttributedString* formattedAttributedString(NSArray *identifiers, double fontSize, UIColor *textColor, NSString *apiKey, NSString *dateLocale)
{
    @autoreleasepool {
        NSMutableAttributedString* mutableString = [[NSMutableAttributedString alloc] init];
        
        if (identifiers) {
            for (id idInfo in identifiers) {
                NSDictionary *parsedInfo = idInfo;
                NSInteger parsedID = [parsedInfo valueForKey:@"widgetID"] ? [[parsedInfo valueForKey:@"widgetID"] integerValue] : 0;
                formatParsedInfo(parsedInfo, parsedID, mutableString, fontSize, textColor, apiKey, dateLocale);
            }
        } else {
            return nil;
        }
        
        return [mutableString copy];
    }
}

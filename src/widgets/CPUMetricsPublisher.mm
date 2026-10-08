//
//  CPUMetricsPublisher.mm
//  Helium
//
//  Writes Helium's CPU readings to a shared file once a second, so SysProbe (a
//  separate process on the same device) can display the *same* numbers.
//
//  ## Why a shared file at all
//
//  Two processes sampling independently can never agree: their sampling phases are
//  offset, and — for the clock — the busy-loop probe each one runs fights the other
//  for a performance core, so neither reads cleanly. The only way two readouts can
//  be identical is if one of them is the sole producer and the other consumes it.
//
//  Helium's HUD is the natural producer: it is launched by a LaunchDaemon and runs
//  for as long as the device is up, whereas SysProbe is an app that may be
//  suspended. Both are unsandboxed (see ent.plist / SysProbe.entitlements), so a
//  plain file works and needs no IPC setup.
//
//  ## File format
//
//  JSON, written atomically:
//
//    { "ts": <unix seconds, float>,   // freshness check for the reader
//      "usage": <0..1, all-core average>,
//      "per_core": [<0..1>, ...],
//      "freq_mhz": <int>,             // 0 = no reading
//      "freq_source": "ioreport" | "probe",
//      "usage_mode": 0,               // 0 = average (kept for future use)
//      "writer": "helium" }
//
//  Two paths are written: /var/tmp is the primary, the Caches copy survives a
//  reboot and covers setups where /var/tmp is not writable.
//
//  ## Sampling cadence
//
//  Deliberately decoupled from the HUD's Update Interval. If the publisher used the
//  widget's own interval, a user who set it to 10 s would make SysProbe's readout
//  ten seconds stale. One second is the floor that matters here; the clock probe
//  keeps its own 3 s throttle inside WidgetManager.mm.
//

#import "CPUMetricsPublisher.h"
#import "CPUFrequencyReal.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <unistd.h>   // getuid — only the root HUD can read IOReport CPU frequency

// Provided by WidgetManager.mm. These must be declared `extern "C"`: this file is
// Objective-C++, so a plain extern would be name-mangled and fail to link against
// the C-linkage definitions.
extern "C" double HeliumCPUUsageFraction(void);
extern "C" NSArray<NSNumber *> *HeliumCPUPerCoreFractions(void);
extern "C" uint64_t HeliumCPUFrequencyKHz(void);
extern "C" void HeliumCPUFrequencyKick(void);

static dispatch_source_t gPublisherTimer = NULL;

static const NSTimeInterval kPublishIntervalSeconds = 1.0;

static NSArray<NSString *> *sharedMetricPaths(void)
{
    return @[ @"/var/tmp/cpu_metrics.json",
              @"/var/mobile/Library/Caches/cpu_metrics.json" ];
}

static void publishOnce(void)
{
    @autoreleasepool {
        // The HUD ("-hud", root) is the authoritative publisher: it runs for as long
        // as the device is up and refreshes the file every second. So the main app
        // has nothing to add while the HUD is alive — and running a second busy-loop
        // probe there would only fight the HUD's for a performance core and heat the
        // device. The main app therefore publishes ONLY when the file has gone stale,
        // i.e. when the HUD is not writing: it is a backup, not a peer.
        if (getuid() != 0) {
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            for (NSString *path in sharedMetricPaths()) {
                NSData *data = [NSData dataWithContentsOfFile:path];
                if (!data) continue;
                NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (![j isKindOfClass:[NSDictionary class]]) continue;
                NSTimeInterval t = [j[@"ts"] doubleValue];
                if (t > 0 && (now - t) < 3.0) {
                    return;   // the HUD is publishing — nothing for us to do
                }
            }
        }

        double usage = HeliumCPUUsageFraction();
        NSArray<NSNumber *> *perCore = HeliumCPUPerCoreFractions() ?: @[];

        // IOReport is unusable on this device, so there is no real reading to
        // preserve. The old "read the shared file back and keep an ioreport reading"
        // step was therefore pure waste — two file reads + two JSON parses every
        // second, hunting for a value that can never appear. Removed.
        uint64_t mhz = 0;
        NSString *source = @"probe";
        if (getuid() == 0) {
            // HUD (root daemon): try the real DVFS residency first. On this device it
            // always returns 0, so we fall straight through to the probe below.
            mhz = helium_real_cpu_frequency_mhz();
            if (mhz > 0) source = @"ioreport";
        }
        if (mhz == 0) {
            // Busy-loop probe (peak achievable clock, not the live DVFS step).
            HeliumCPUFrequencyKick();
            mhz = HeliumCPUFrequencyKHz() / 1000ull;
            source = @"probe";
        }

        NSDictionary *payload = @{
            @"ts": @([[NSDate date] timeIntervalSince1970]),
            @"usage": @(usage),
            @"per_core": perCore,
            @"freq_mhz": @(mhz),
            @"freq_source": source,
            @"usage_mode": @(0),
            @"writer": @"helium",
        };

        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        if (!data) return;

        for (NSString *path in sharedMetricPaths()) {
            @try {
                [data writeToFile:path atomically:YES];
            } @catch (NSException *e) {
                // A path that is not writable on this setup is not fatal — the other
                // one still carries the value.
            }
        }
    }
}

void helium_start_cpu_metrics_publisher(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_queue_create("com.leemin.helium.cpumetrics",
                                                       DISPATCH_QUEUE_SERIAL);

        // The IOReport / device-tree report is now **opt-in**, and runs on its OWN
        // queue.
        //
        // Why: building it enumerates every channel IOReport exposes (thousands),
        // attempts a whole-set subscription and walks ~700 groups — heavy enough to
        // be felt, and it used to run on this very serial queue, which delayed the
        // publisher's first write. IOReport turned out to be unusable on this device,
        // so by default we do NOT build it. To get a report, create
        //     /var/mobile/Documents/HeliumCPUFreqDiag.enable
        // and reopen the app.
        //
        // The separate queue means that even when enabled it can never block the
        // 1 Hz publish loop below.
        dispatch_queue_t diagQueue = dispatch_queue_create("com.leemin.helium.cpudiag",
                                                           DISPATCH_QUEUE_SERIAL);
        dispatch_async(diagQueue, ^{
            if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/Documents/HeliumCPUFreqDiag.enable"]) {
                return;
            }
            @try { (void)helium_real_cpu_frequency_diagnosis(); } @catch (NSException *e) { }
        });

        gPublisherTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        if (!gPublisherTimer) return;

        // First fire half a second in (the first CPU sample has no baseline, so an
        // immediate publish would write a fabricated 0 %), then every second.
        dispatch_source_set_timer(gPublisherTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                  (uint64_t)(kPublishIntervalSeconds * NSEC_PER_SEC),
                                  100ull * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gPublisherTimer, ^{
            publishOnce();
        });
        dispatch_resume(gPublisherTimer);
    });
}

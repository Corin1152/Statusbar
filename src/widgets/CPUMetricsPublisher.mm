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
//  Two paths are *tried*, in this order: /var/tmp is the primary, and the Caches copy
//  is written only when the primary write fails — it covers the setups where /var/tmp
//  is not usable, which is the only reason it exists. (Until 0.25 both were written
//  unconditionally, which doubled the per-second file I/O to keep a fallback that
//  nothing ever read.)
//
//  ## This file is the contract
//
//  **These two paths are the only cross-process contract between Helium and
//  SysProbe.** There is no App Group and no XPC: the reader opens the same file and
//  parses the same keys. So any change to the following breaks the other app
//  *silently* — it keeps reading, finds no such key, and falls back to a zero or a
//  dash, with nothing in any log to say why:
//
//    * the key names and their types,
//    * the units (0..1 rather than 0..100; MHz rather than Hz),
//    * the two paths, or which of them is tried first,
//    * the freshness window the reader applies to `ts`.
//
//  Changing any of them means changing SysProbe's
//  `Sources/Shared/Hardware/CPUSharedMetrics.swift` in the same breath and shipping
//  both apps together. That reader is deliberately forgiving — unknown keys are
//  ignored, a missing file is not an error — which is exactly why a mismatch shows
//  up as a wrong number rather than as a failure.
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
#import <os/lock.h>   // os_unfair_lock — 保护下面的暂停状态
#import <unistd.h>   // getuid — only the root HUD can read IOReport CPU frequency

// Provided by WidgetManager.mm. These must be declared `extern "C"`: this file is
// Objective-C++, so a plain extern would be name-mangled and fail to link against
// the C-linkage definitions.
extern "C" double HeliumCPUUsageFraction(void);
extern "C" NSArray<NSNumber *> *HeliumCPUPerCoreFractions(void);
extern "C" uint64_t HeliumCPUFrequencyKHz(void);
extern "C" void HeliumCPUFrequencyKick(void);
extern "C" BOOL HeliumCPUFrequencyWidgetInUse(void);

static dispatch_source_t gPublisherTimer = NULL;
static dispatch_queue_t gPublisherQueue = NULL;

/// 暂停状态。三样都由 `gPublisherLock` 保护，而且**只能**在持锁时读写：
///
///   `gPublisherPaused`   期望状态（锁屏时为 YES）。可能在 timer 建起来之前就被设上
///                        （HUD 起来时屏幕可能就是锁着的），所以它是独立的一份意图，
///                        创建 timer 时再按它决定要不要 resume。
///   `gPublisherRunning`  timer 当前是否已 resume。`dispatch_suspend` / `dispatch_resume`
///                        必须严格配对，多一次就崩，所以用这个标志当唯一事实来源，
///                        不要靠别的东西推断。
static os_unfair_lock gPublisherLock = OS_UNFAIR_LOCK_INIT;
static BOOL gPublisherPaused = NO;
static BOOL gPublisherRunning = NO;

/// 把 timer 的挂起状态对齐到 `gPublisherPaused`。必须在持锁时调用。
static void applyPublisherPauseStateLocked(void)
{
    if (!gPublisherTimer) return;               // 还没建；建的时候会读 gPublisherPaused

    // 「已挂起」⇔「未运行」，两者一致就无事可做。
    if (gPublisherPaused == !gPublisherRunning) return;

    if (gPublisherPaused) {
        dispatch_suspend(gPublisherTimer);
        gPublisherRunning = NO;
    } else {
        dispatch_resume(gPublisherTimer);
        gPublisherRunning = YES;
    }
}

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
            //
            // **只在真的有人看这个数的时候才烧它。**
            //
            // 探针是 2 个性能核各约 62 ms 的忙循环，而且它的线程 QoS 是
            // `QOS_CLASS_USER_INTERACTIVE`（不那样就上不了性能核、读不到顶档）——
            // 也就是说它**会抢占前台**。原来这里是每秒无条件 kick 一次，于是哪怕
            // HUD 上根本没有 CPU 频率部件，每 5 秒也照样来一次双性能核饱和：在
            // 2 + 4 的 A11 上，那就是肉眼可见的周期性掉帧，而且是 HUD 自己造成的。
            //
            // 读这个数的只有两处：HUD 上的频率部件，和 SysProbe。前者由
            // `HeliumCPUFrequencyWidgetInUse()` 回答；后者读共享文件，读不到
            // （或读到 `freq_mhz: 0`）会回落到它自己的采样 —— 那条降级路径本来
            // 就在（见 SysProbe 的 `CPUSharedMetrics.swift`）。
            //
            // 文件格式没变，键还是那几个；变的只是 `freq_mhz` 在没人看的时候写 0。
            if (HeliumCPUFrequencyWidgetInUse()) {
                HeliumCPUFrequencyKick();
                mhz = HeliumCPUFrequencyKHz() / 1000ull;
            }
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

        // 只写主路径；写失败了才写备用路径。
        //
        // 原来是无条件两个都写，于是稳态里每秒两次原子写（每次都是「写临时文件 + rename」），
        // 而备用那份**没有任何人会读到** —— 读方（SysProbe 的主 App 与负一屏扩展）是按顺序
        // 试路径的，先试 `/var/tmp`；扩展带 no-sandbox 与绝对路径例外，读得到
        // （见 Support/TodayExtension.entitlements）。所以备用那份的全部意义就是
        // 「覆盖 /var/tmp 不可写的情况」，而 `writeToFile:` 的返回值正好就是那个判据。
        //
        // 这不是契约的一部分：读方只关心「两个路径、按这个顺序试」，不关心它们各自被写的
        // 频率。改这里不需要动 SysProbe。
        NSArray<NSString *> *paths = sharedMetricPaths();
        BOOL wrotePrimary = NO;
        @try {
            wrotePrimary = [data writeToFile:paths[0] atomically:YES];
        } @catch (NSException *e) {
            wrotePrimary = NO;
        }
        if (!wrotePrimary) {
            @try {
                [data writeToFile:paths[1] atomically:YES];
            } @catch (NSException *e) {
                // 两个路径都写不了：这一拍没落盘。不致命 —— 读方会读到旧值，或者
                // 因为超出新鲜度窗口而显示「—」。
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

        os_unfair_lock_lock(&gPublisherLock);
        gPublisherQueue = queue;
        // `dispatch_source_create` 出来就是挂起态，所以「不 resume」天然就是暂停。
        // `gPublisherPaused` 可能在这次调用之前就被设上了（见头文件）。
        if (gPublisherPaused) {
            gPublisherRunning = NO;
        } else {
            dispatch_resume(gPublisherTimer);
            gPublisherRunning = YES;
        }
        os_unfair_lock_unlock(&gPublisherLock);
    });
}

void helium_set_cpu_metrics_publisher_paused(BOOL paused)
{
    dispatch_queue_t publishNow = NULL;

    os_unfair_lock_lock(&gPublisherLock);
    BOOL resuming = (gPublisherPaused && !paused);
    gPublisherPaused = paused;
    applyPublisherPauseStateLocked();
    // 立刻补一拍得在同一个队列上排队，才保证「先 resume、再发布」的顺序。
    if (resuming) publishNow = gPublisherQueue;
    os_unfair_lock_unlock(&gPublisherLock);

    if (!publishNow) return;

    // 解锁时补这一拍，是为了消掉一个竞态：读方的新鲜度窗口是 5 秒，而锁屏期间文件是
    // 停更的。不补的话，用户解锁后立刻划到负一屏，扩展可能正好读到一份刚过期（或即将
    // 过期）的文件 —— 那会显示成「—」，而状态栏上明明有数。
    dispatch_async(publishNow, ^{
        publishOnce();
    });
}

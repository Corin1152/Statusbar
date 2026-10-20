//
//  CPUFrequencyGovernor.mm
//  Helium
//
//  Implementation of the busy-pulse frequency governor. Read the header first: the
//  short version is that this cannot set a clock, so it buys frequency with work,
//  and the work is visible as CPU usage. That is a property of the platform, not a
//  limitation of this file.
//
//  ## Shape
//
//    apply(mode) -> start/stop N worker threads
//    worker:  [measure] -> [decide] -> [spin onMs] -> [sleep offMs] -> repeat
//
//  The measurement is what separates this from a fixed-duty heater: IOReport's
//  weighted-average clock tells us whether the cluster is already where we want it,
//  and if it is, the pulse is skipped entirely. On a device where the cluster sits
//  at 2.0 GHz on its own, the governor does almost nothing — which is the correct
//  behaviour and also the cheapest one.
//
//  ## Why the spin is hand-written assembly
//
//  The same reason CPUFrequencyProbe.mm uses it: `nanosleep` would let the core go
//  idle, which is precisely the signal CLPC reads as "no demand". A dependent
//  `add` chain keeps the core retired-busy without touching memory, so it raises
//  demand without competing for the cache or the memory bus with the foreground.
//
//  ## Thread count
//
//  Two, because this is a 2 + 4 part and CLPC will not grant the top gear for a
//  single busy performance core (measured in CPUFrequencyProbe.mm's comments: one
//  core tops out around 2030 MHz, two reach 2376). One thread would be cheaper but
//  would not reach the gear the feature exists to reach.
//

#import "CPUFrequencyGovernor.h"
#import "CPUFrequencyReal.h"

#import <Foundation/Foundation.h>
#import <atomic>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <pthread.h>
#import <pthread/qos.h>
#import <stdlib.h>
#import <string.h>
#import <sys/qos.h>
#import <time.h>

#if defined(__arm64__)

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

static std::atomic<int>      gMode{HeliumGovernorModeOff};
static std::atomic<bool>     gSuspended{false};
static std::atomic<bool>     gWorkersShouldRun{false};
static std::atomic<bool>     gWorkersStarted{false};
static std::atomic<uint64_t> gChirpDeadlineTicks{0};
static std::atomic<uint64_t> gLastMeasuredMHz{0};
static std::atomic<uint64_t> gPeakMHz{0};
static std::atomic<int>      gGuardState{0};      // 0 ok, 1 thermal, 2 low-power
static std::atomic<uint64_t> gPulsesFired{0};
static std::atomic<uint64_t> gPulsesSkipped{0};

static os_unfair_lock gStateLock = OS_UNFAIR_LOCK_INIT;

/// Pulse shape per mode, in milliseconds.
typedef struct {
    double onMs;
    double offMs;
    int    threads;
} GovernorShape;

static GovernorShape shapeForMode(int mode)
{
    switch (mode) {
        case HeliumGovernorModeStrong:
            // ~70 % duty: reaches the top gear and holds it. Expect heat.
            return (GovernorShape){ .onMs = 260.0, .offMs = 110.0, .threads = 2 };
        case HeliumGovernorModeLight:
        default:
            // ~15 % duty per core: enough to keep the cluster from dropping to its
            // idle gear, cheap enough that the chassis does not heat up.
            return (GovernorShape){ .onMs = 90.0, .offMs = 520.0, .threads = 2 };
    }
}

// ---------------------------------------------------------------------------
// Time and spin
// ---------------------------------------------------------------------------

static double gNsPerTick = 0.0;

static double gov_ns_per_tick(void)
{
    if (gNsPerTick == 0.0) {
        mach_timebase_info_data_t info;
        if (mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0) {
            gNsPerTick = (double)info.numer / (double)info.denom;
        } else {
            gNsPerTick = 1.0;
        }
    }
    return gNsPerTick;
}

static inline uint64_t gov_read_counter(void)
{
    uint64_t v;
    __asm__ __volatile__("isb\nmrs %0, cntpct_el0" : "=r"(v));
    return v;
}

static uint64_t gov_ticks_for_ms(double ms)
{
    double ns = ms * 1000000.0;
    return (uint64_t)(ns / gov_ns_per_tick());
}

/// 32 dependent adds — one cycle each on every A-series core, so this is a pure
/// "keep the core retired-busy" block. `cc` because the loop's own subs/b.ne uses
/// the flags; the chain register is read back so nothing can be optimised away.
#define GOV_ADD_32                                                             \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"       \
    "add %[c], %[c], #1\n" "add %[c], %[c], #1\n"

/// Busy-spin for `ticks` of the 24 MHz counter, in 256-add chunks (~107 ns at
/// 2.4 GHz) so the counter is read about ten times less often than the chain runs.
__attribute__((noinline))
static void gov_spin_ticks(uint64_t ticks)
{
    if (ticks == 0) return;

    const uint64_t start = gov_read_counter();
    uint64_t chain = 1;
    uint64_t now = start;

    do {
        __asm__ __volatile__(GOV_ADD_32 GOV_ADD_32 GOV_ADD_32 GOV_ADD_32
                             GOV_ADD_32 GOV_ADD_32 GOV_ADD_32 GOV_ADD_32
                             : [c] "+r"(chain)
                             :
                             : "cc");
        now = gov_read_counter();
    } while (now - start < ticks);

    __asm__ __volatile__("" : : "r"(chain) : "memory");
}

static void gov_sleep_ms(double ms)
{
    if (ms <= 0) return;
    struct timespec ts;
    ts.tv_sec = (time_t)(ms / 1000.0);
    ts.tv_nsec = (long)((ms - (double)ts.tv_sec * 1000.0) * 1000000.0);
    nanosleep(&ts, NULL);
}

// ---------------------------------------------------------------------------
// Guards
// ---------------------------------------------------------------------------

/// 0 = clear, 1 = thermal, 2 = low power. Checked once per second, not per pulse:
/// `thermalState` and `isLowPowerModeEnabled` are cheap but not free, and a state
/// change that takes a second to be honoured is fine for a feature like this.
static int gov_evaluate_guards(void)
{
    NSProcessInfo *info = [NSProcessInfo processInfo];

    if (info.isLowPowerModeEnabled) {
        return 2;
    }

    switch (info.thermalState) {
        case NSProcessInfoThermalStateSerious:
        case NSProcessInfoThermalStateCritical:
            return 1;
        default:
            break;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Worker
// ---------------------------------------------------------------------------

static void *gov_worker_main(void *context)
{
    (void)context;

    // user-interactive is not a luxury here: it is what puts this thread on a
    // performance core, and a busy efficiency core does not raise the gear we are
    // trying to raise.
    (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    double lastGuardCheck = -1000.0;

    while (gWorkersShouldRun.load()) {
        const int mode = gMode.load();
        if (mode == HeliumGovernorModeOff || gSuspended.load()) {
            gov_sleep_ms(120);
            continue;
        }

        const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastGuardCheck >= 1.0) {
            lastGuardCheck = now;
            const int guard = gov_evaluate_guards();
            gGuardState.store(guard);
            if (guard != 0) {
                // Stop, do not merely slow down: pushing past the thermal limit is
                // what makes the device slower than leaving it alone.
                gov_sleep_ms(1000);
                continue;
            }
        } else if (gGuardState.load() != 0) {
            gov_sleep_ms(500);
            continue;
        }

        GovernorShape shape = shapeForMode(mode);

        // Feedback: has the cluster already reached the gear we are paying for?
        uint64_t measured = helium_real_cpu_frequency_mhz_fast();
        if (measured > 0) {
            gLastMeasuredMHz.store(measured);
        }
        uint64_t peak = gPeakMHz.load();
        if (peak == 0) {
            uint64_t p = helium_real_cpu_peak_mhz();
            if (p > 0) {
                peak = p;
                gPeakMHz.store(p);
            }
        }

        // "Near the top" means within 8 %. The band exists because the weighted
        // average over a window is always a little below the instantaneous gear.
        if (peak > 0 && measured > 0 && measured >= (uint64_t)((double)peak * 0.92)) {
            gPulsesSkipped.fetch_add(1);
            gov_sleep_ms(shape.offMs);
            continue;
        }

        // An event-driven chirp extends this pulse rather than adding a second one:
        // stacking pulses would double the thread count and the contention with the
        // foreground, which is the opposite of what priming is for.
        double onMs = shape.onMs;
        const uint64_t chirpUntil = gChirpDeadlineTicks.load();
        if (chirpUntil > 0) {
            const uint64_t nowTicks = gov_read_counter();
            if (nowTicks < chirpUntil) {
                const double remainingMs =
                    (double)(chirpUntil - nowTicks) * gov_ns_per_tick() / 1000000.0;
                if (remainingMs > onMs) onMs = remainingMs;
            }
            gChirpDeadlineTicks.store(0);
        }

        gov_spin_ticks(gov_ticks_for_ms(onMs));
        gPulsesFired.fetch_add(1);

        gov_sleep_ms(shape.offMs);
    }

    return NULL;
}

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

static void gov_start_workers_if_needed(int threads)
{
    if (gWorkersStarted.load()) return;

    gWorkersStarted.store(true);
    gWorkersShouldRun.store(true);

    for (int i = 0; i < threads; i++) {
        pthread_t thread;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        const int rc = pthread_create(&thread, &attr, gov_worker_main, NULL);
        pthread_attr_destroy(&attr);
        if (rc != 0) {
            // Fewer threads than asked for is a degraded governor, not a failure:
            // one thread still raises the gear of the core it lands on.
            break;
        }
    }
}

static void gov_stop_workers(void)
{
    // The threads are **not** torn down here, on purpose.
    //
    // They are detached, so there is nothing to join, and a stop-then-start cycle
    // (the user flipping the switch) would otherwise leave the previous pair parked
    // in their off-period while a new pair is created on top — four spinning threads
    // instead of two, which is exactly the contention this feature is supposed to
    // avoid. Instead the workers live for the life of the process and park themselves
    // whenever the mode is Off (they wake once every 120 ms to look).
    //
    // Cost of a parked worker: one wake-up per 120 ms doing two atomic loads. That is
    // below the noise floor of everything else the HUD does.
    gChirpDeadlineTicks.store(0);
}

void helium_governor_apply(int mode)
{
    if (mode < HeliumGovernorModeOff) mode = HeliumGovernorModeOff;
    if (mode > HeliumGovernorModeStrong) mode = HeliumGovernorModeStrong;

    const int previous = gMode.exchange(mode);

    if (mode == HeliumGovernorModeOff) {
        gov_stop_workers();
        return;
    }

    // Workers are permanent (see gov_stop_workers); a parked worker picks the new
    // mode up on its next wake-up, so this only has to create them the first time.
    gWorkersShouldRun.store(true);
    gov_start_workers_if_needed(shapeForMode(mode).threads);

    if (previous != mode) {
        os_unfair_lock_lock(&gStateLock);
        gPulsesFired.store(0);
        gPulsesSkipped.store(0);
        os_unfair_lock_unlock(&gStateLock);
    }
}

int helium_governor_mode(void)
{
    return gMode.load();
}

void helium_governor_chirp(int milliseconds)
{
    if (gMode.load() == HeliumGovernorModeOff) return;
    if (gSuspended.load()) return;
    if (milliseconds <= 0) return;

    const uint64_t until = gov_read_counter() + gov_ticks_for_ms((double)milliseconds);
    uint64_t current = gChirpDeadlineTicks.load();
    while (until > current && !gChirpDeadlineTicks.compare_exchange_weak(current, until)) {
        // retry with the refreshed value
    }
}

void helium_governor_suspend(BOOL suspended)
{
    gSuspended.store(suspended == YES);
}

NSString *helium_governor_status(void)
{
    const int mode = gMode.load();
    GovernorShape shape = shapeForMode(mode);

    const char *guard = "ok";
    switch (gGuardState.load()) {
        case 1: guard = "thermal"; break;
        case 2: guard = "low-power"; break;
        default: break;
    }

    return [NSString stringWithFormat:
            @"mode=%d (%@) suspended=%d guard=%s\n"
             "peak=%llu MHz measured=%llu MHz pulses=%llu skipped=%llu\n"
             "shape=on %.0f ms / off %.0f ms x %d threads",
            mode,
            mode == 0 ? @"off" : (mode == 1 ? @"light" : @"strong"),
            gSuspended.load() ? 1 : 0,
            guard,
            (unsigned long long)gPeakMHz.load(),
            (unsigned long long)gLastMeasuredMHz.load(),
            (unsigned long long)gPulsesFired.load(),
            (unsigned long long)gPulsesSkipped.load(),
            shape.onMs, shape.offMs, shape.threads];
}

#else /* !__arm64__ */

void helium_governor_apply(int mode) { (void)mode; }
int helium_governor_mode(void) { return 0; }
void helium_governor_chirp(int milliseconds) { (void)milliseconds; }
void helium_governor_suspend(BOOL suspended) { (void)suspended; }
NSString *helium_governor_status(void) { return @"unavailable (not arm64)"; }

#endif /* __arm64__ */

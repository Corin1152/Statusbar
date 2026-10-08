//
//  CPUFrequencyProbe.mm
//  Helium
//
//  Measures the CPU's current clock by running a loop whose cycle count is known.
//  Ported from SysProbe (Apache-2.0) — the same technique CPU-X uses for its
//  "CPU Current Speed" row.
//
//  ## Why measure it instead of reading it
//
//  iOS gives an app no way to read the clock:
//
//    * `hw.cpufrequency` / `hw.cpufrequency_max` are macOS-only sysctls and fail on
//      device;
//    * IOReport (the `powermetrics` path) needs `com.apple.private.ioreport`;
//    * the device tree's `voltage-states` gives the *gear table*, not the gear the
//      CPU is actually in right now.
//
//  ## How it works
//
//  On Apple's ARM64 cores a *dependent* `add` has a latency of exactly one cycle.
//  So 32 back-to-back adds are 32 cycles — and the loop's own `subs` / `b.ne` sit
//  off that dependency chain, which an out-of-order core overlaps for free.
//
//  Run a fixed number of iterations, time it, frequency = cycles / seconds.
//
//  The chain is latency-bound rather than throughput-bound, so the result does not
//  depend on the core's issue width: "one cycle per add" holds on every A-series
//  part without a per-microarchitecture table. Written the other way round —
//  independent adds — the probe would measure the IPC ceiling, not the clock.
//
//  ## Timing: `cntpct_el0`, not `clock_gettime` (0.21)
//
//  Up to 0.20 the two ends of the loop were read with `clock_gettime(CLOCK_MONOTONIC)`.
//  That is the wrong instrument, and taking CPU-X apart showed exactly what to use
//  instead: its probe (at 0x100128250 in ARMCPUZ) is
//
//      isb ; mrs x1, cntpct_el0 ; <spin> ; isb ; mrs x0, cntpct_el0 ; sub x0, x0, x1
//
//  — the ARM generic counter read on either side of the loop, with `isb` at both ends.
//
//    * `mrs cntpct_el0` is a **single instruction**. `clock_gettime` goes through the
//      commpage, costs tens of cycles, and — the real problem — costs a *variable*
//      number of them depending on what else the core is doing. That variance lands
//      straight in the result, and it is why repeated rounds disagreed with each other.
//    * `isb` stops the out-of-order core from hoisting the closing read above the loop
//      or sinking the opening read into it. Without it the "elapsed" span can come out
//      short by however many cycles the core managed to overlap, which reads as a
//      spuriously *high* clock.
//
//  The counter ticks at `cntfrq_el0` (24 MHz on every A-series part we care about);
//  `mach_timebase_info` hands back the tick→nanosecond ratio with no sysctl at all.
//
//  ## Why it gets threads of its own — and why *two* of them (0.23)
//
//  Clocking is per-core. A thread raises its own QoS to user-interactive first, so
//  the scheduler puts it on a performance core and lifts the clock there; doing that
//  to the *caller's* thread would be rude, since it may be a cooperative pool
//  thread. Apple's clock response takes tens of milliseconds, hence the warm-up
//  before the measured rounds.
//
//  Up to 0.22 that was **one** thread, and one thread is why the readout used to
//  cap out low under load. This device is a 2 + 4 part: two Monsoon performance
//  cores and four Mistral efficiency cores. CLPC will not hand out the *top* gear
//  (2376 MHz) for a single busy performance core — it wants the whole performance
//  cluster loaded before it goes there. So a one-thread probe reports the gear the
//  controller grants *one* core, which under load sat around 2030 even when the
//  device was visibly working. That is a real clock, but it is the wrong question:
//  "how fast is the CPU right now" means the cluster, not one core of it.
//
//  Two threads is the smallest number that answers it. They raise the same QoS, land
//  on the two performance cores, and hold both of them busy for the warm-up and the
//  measured rounds, so CLPC sees a loaded performance cluster and grants the top
//  gear. Each thread measures its own core and the higher of the two is reported.
//
//  ## Cost
//
//  The sample is throttled to one every 5 s (see WidgetManager.mm), and a sample is
//  ~50 ms of warm-up plus ~12 ms of measurement per thread. Two threads therefore
//  spend about 2 x 62 ms / 5000 ms, i.e. **~2.5 %** of the performance cluster —
//  the same order as one thread was, because the sample rate is low. That is the
//  trade this probe makes, deliberately: it is the difference between a number that
//  answers "how fast is this device running" and one that answers "how fast did a
//  single core happen to be scheduled".
//
//  It also means the readout sits near the top gear whenever it samples, idle or
//  not — which is exactly what CPU-X shows, and for exactly the same reason: the
//  measuring tool is itself part of the load it reports. That is a fair thing for a
//  monitor to do as long as it is not doing it every frame, and at one sample per
//  five seconds it is not.
//

#import "CPUFrequencyProbe.h"

#if defined(__arm64__)

#import <mach/mach_time.h>
#import <pthread.h>
#import <pthread/qos.h>
#import <stdlib.h>
#import <sys/qos.h>
#import <time.h>

/// Dependent adds per iteration. Changing this means changing the asm below.
#define PROBE_UNROLL 32

/// Warm-up: spin until the clock has had time to reach its target.
///
/// Apple's DVFS response takes **tens of milliseconds**, so a *fixed iteration
/// count* is the wrong shape: at a low starting clock it warms up for far less wall
/// time than intended, and the measured rounds then sample a **partially ramped**
/// clock — which is exactly why the readout used to sit at ~1000-2000 MHz and never
/// reach the top gear (2376 on this device), even under load. Spin in fixed chunks
/// until ~50 ms of wall time has elapsed instead.
#define PROBE_WARMUP_TARGET_NS (50ull * 1000000ull)
#define PROBE_WARMUP_CHUNK 300000

/// Measured rounds: ~0.5 ms each, twenty-four of them, fastest one wins.
///
/// The window used to be 2.5 ms x 6. That was tuned for the *idle* case and it is
/// the wrong shape for the *loaded* one, which is where the reading actually
/// matters — a user who opens a game wants to see the clock climb, not to be told
/// the CPU is still at its idle gear.
///
/// The reason is that the elapsed time here is wall-clock: a round that gets
/// preempted mid-spin reports the preemption as if the loop had simply taken
/// longer, so it comes out **low**. Under load the odds of a 2.5 ms window being
/// interrupted are high, and six draws is not enough to be confident that one of
/// them was clean — which is exactly why a fully loaded device still read ~2030
/// instead of the top gear.
///
/// Shortening the window and multiplying the count fixes that directly: at ~0.5 ms
/// a round is short enough that the scheduler usually leaves it alone, and 24 draws
/// make it very unlikely that *all* of them get hit. The per-round overhead (the
/// two `isb` + the counter reads, a couple hundred cycles) is still under 0.01% of
/// a 0.5 ms round, so nothing is lost by cutting the window this small.
///
/// Total spin is unchanged: 24 x 0.5 ms is the same 12 ms the 6 x 2.5 ms used.
#define PROBE_MEASURE_ROUNDS 40000
#define PROBE_MEASURE_ROUND_COUNT 24

/// Probe threads: one per performance core.
///
/// Two is not a tuning knob — it is the width of the performance cluster on this
/// class of part, and the minimum that makes CLPC grant the top gear (see the header
/// comment). Adding more would only add battery cost: the readout is a single number
/// and it is the *fastest* core's clock, so a third thread on an efficiency core can
/// never raise it.
#define PROBE_THREAD_COUNT 2

/// Plausibility window, in MHz.
///
/// SysProbe validates against a chip->nominal table and falls back to the nominal
/// figure. Helium has no such table (and no per-chip maintenance burden worth
/// taking on for a status-bar readout), so a sanity band stands in for it: it
/// catches the model breaking down — which is the failure that matters, since a
/// garbled number is worse than no number — without rejecting genuine
/// down-clocking, which is a real reading of this device right now.
#define PROBE_MIN_PLAUSIBLE_MHZ 200
#define PROBE_MAX_PLAUSIBLE_MHZ 6000

/// Nanoseconds per `cntpct_el0` tick, from the kernel's timebase.
///
/// Cached after the first call: `mach_timebase_info` is cheap but not free, and the
/// ratio is a property of the SoC that cannot change under us. On a 24 MHz counter
/// this comes back as 125/3, i.e. 41.667 ns per tick.
static double probe_nanoseconds_per_tick(void)
{
    static double ratio = 0.0;
    if (ratio == 0.0) {
        mach_timebase_info_data_t info;
        if (mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0) {
            ratio = (double)info.numer / (double)info.denom;
        } else {
            ratio = 1.0;   // unreachable in practice; keeps the maths finite if it were
        }
    }
    return ratio;
}

/// Run `iterations` rounds and return the elapsed `cntpct_el0` ticks.
///
/// `__volatile__` is load-bearing: without it the compiler deletes the whole loop
/// as dead code. `"cc"` declares that it clobbers the flags (`subs`). The counter
/// registers are marked early-clobber so the compiler cannot hand them a register
/// that one of the loop's own operands still occupies.
///
/// `noinline` is load-bearing too, and for a less obvious reason: the body defines
/// the numeric label `1:`. If the compiler inlines a copy of this function at each
/// of its call sites, that label is defined more than once in the same translation
/// unit and the assembler rejects the file. It was inlined-by-accident territory
/// before; saying so outright costs one call per round out of a 2.5 ms round.
__attribute__((noinline))
static uint64_t probe_run_ticks(uint64_t iterations)
{
    uint64_t counter = iterations;
    uint64_t chain = 1;
    uint64_t start = 0;
    uint64_t end = 0;

    __asm__ __volatile__(
        "isb\n"
        "mrs %[start], cntpct_el0\n"
        "1:\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "add %[chain], %[chain], #1\n"
        "subs %[counter], %[counter], #1\n"
        "b.ne 1b\n"
        "isb\n"
        "mrs %[end], cntpct_el0\n"
        : [start] "=&r"(start), [end] "=&r"(end),
          [counter] "+r"(counter), [chain] "+r"(chain)
        :
        : "cc");

    // Consume the chain's final value so the compiler cannot decide the loop was
    // pointless. The value itself is of no interest — only the time it took.
    __asm__ __volatile__("" : : "r"(chain) : "memory");

    return end - start;
}

/// Thread entry point: raise the QoS, then measure.
static void *probe_thread_main(void *context)
{
    // user-interactive puts this thread on a performance core and lifts the clock
    // there. The return value is ignored on purpose: if the QoS cannot be raised we
    // still measure, the reading is just more likely to come out low.
    (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    const double ns_per_tick = probe_nanoseconds_per_tick();

    // Warm up until ~50 ms of wall time has elapsed, so the clock is fully ramped
    // before the measured rounds begin (see PROBE_WARMUP_TARGET_NS). Spinning in
    // chunks rather than a single fixed count is what makes this time-based.
    uint64_t warmed = 0;
    while (warmed < PROBE_WARMUP_TARGET_NS) {
        uint64_t ticks = probe_run_ticks(PROBE_WARMUP_CHUNK);
        if (ticks == 0) break;   // never expected; guards against a spin if the counter misbehaves
        warmed += (uint64_t)((double)ticks * ns_per_tick);
    }

    uint64_t best = 0;
    for (int round = 0; round < PROBE_MEASURE_ROUND_COUNT; round++) {
        uint64_t ticks = probe_run_ticks(PROBE_MEASURE_ROUNDS);
        if (ticks == 0) {
            continue;
        }
        // cycles / nanosecond == GHz; x1000 gives MHz. Done in double rather than
        // integer maths because ticks*1000 overflows a 64-bit product long before
        // the quotient gets anywhere near interesting.
        double nanoseconds = (double)ticks * ns_per_tick;
        double cycles = (double)PROBE_MEASURE_ROUNDS * (double)PROBE_UNROLL;
        uint64_t megahertz = (uint64_t)(cycles * 1000.0 / nanoseconds);
        if (megahertz > best) {
            best = megahertz;
        }
    }

    *(uint64_t *)context = best;
    return NULL;
}

uint64_t helium_measure_cpu_frequency_mhz(void)
{
    // One thread per performance core, started back to back so both cores are busy
    // for the same warm-up window. Each writes its own slot; the slots are separate
    // objects, so no synchronisation is needed between them.
    uint64_t results[PROBE_THREAD_COUNT] = {0};
    pthread_t threads[PROBE_THREAD_COUNT];
    int started[PROBE_THREAD_COUNT];
    int startedCount = 0;

    for (int i = 0; i < PROBE_THREAD_COUNT; i++) {
        if (pthread_create(&threads[i], NULL, probe_thread_main, &results[i]) == 0) {
            started[startedCount++] = i;
        }
    }

    if (startedCount == 0) {
        return 0;
    }

    // Join every thread that actually started — a partial start must not leave one
    // behind for the next sample to trip over, and must not join a slot that never
    // got a thread in it.
    uint64_t megahertz = 0;
    for (int k = 0; k < startedCount; k++) {
        int i = started[k];
        pthread_join(threads[i], NULL);
        if (results[i] > megahertz) {
            megahertz = results[i];   // the fastest core is the clock that matters
        }
    }

    if (megahertz < PROBE_MIN_PLAUSIBLE_MHZ || megahertz > PROBE_MAX_PLAUSIBLE_MHZ) {
        return 0;
    }
    return megahertz;
}

#else /* !__arm64__ */

// On the simulator (and on x86) this assembly means nothing — the clock it would
// measure is not the device's clock. Returning 0 makes the widget show its
// "no reading" placeholder instead of a fabricated number.
uint64_t helium_measure_cpu_frequency_mhz(void)
{
    return 0;
}

#endif /* __arm64__ */

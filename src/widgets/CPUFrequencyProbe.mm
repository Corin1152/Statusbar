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
//  ## Why it gets a thread of its own
//
//  Clocking is per-core. The thread raises its own QoS to user-interactive first,
//  so the scheduler puts it on a performance core and lifts the clock there; doing
//  that to the *caller's* thread would be rude, since it may be a cooperative pool
//  thread. Apple's clock response takes tens of milliseconds, hence the warm-up
//  before the measured rounds.
//
//  ## What this probe is not
//
//  It reports how fast *this thread's core* ran during the measurement, not the
//  instantaneous DVFS gear of the whole cluster. CPU-X reads higher and more
//  steadily than this for one reason: it keeps a spinning thread pinned to *every*
//  core, so the cluster never gets to drop its clock. That is a real reading of a
//  real clock — of a machine that CPU-X is itself holding at full tilt. Matching it
//  by doing the same thing from a status-bar widget would mean burning battery
//  around the clock to flatter a number, so this probe stays a short burst on one
//  core and the readout is allowed to show the clock actually dropping back.
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

/// Measured rounds: ~2.5 ms each, six of them, best one wins.
///
/// Six rounds rather than five, and a shorter round than before: the reported
/// maximum is only as good as the cleanest round it saw, and a round only has to be
/// long enough for the counter read to be negligible next to the loop (at ~2.5 ms,
/// a couple of hundred cycles of overhead is under 0.01%). Shorter rounds mean more
/// of them fit in the same budget, which raises the odds that at least one lands in
/// a stretch where the scheduler left the thread alone.
#define PROBE_MEASURE_ROUNDS 200000
#define PROBE_MEASURE_ROUND_COUNT 6

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
    uint64_t megahertz = 0;

    pthread_t thread;
    if (pthread_create(&thread, NULL, probe_thread_main, &megahertz) != 0) {
        return 0;
    }
    pthread_join(thread, NULL);

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

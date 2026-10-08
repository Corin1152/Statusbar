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
//  ## Why it gets a thread of its own
//
//  Clocking is per-core. The thread raises its own QoS to user-interactive first,
//  so the scheduler puts it on a performance core and lifts the clock there; doing
//  that to the *caller's* thread would be rude, since it may be a cooperative pool
//  thread. Apple's clock response takes tens of milliseconds, hence the warm-up
//  before the measured rounds.
//

#import "CPUFrequencyProbe.h"

#if defined(__arm64__)

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

/// Measured rounds: ~4 ms each, five of them, best one wins.
///
/// Five rather than three: under load a round is easily interrupted by the
/// scheduler, and the reported maximum is only as good as the cleanest round it saw.
/// Five rounds makes a fully-ramped, uninterrupted sample much more likely.
#define PROBE_MEASURE_ROUNDS 300000
#define PROBE_MEASURE_ROUND_COUNT 5

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

/// Run `iterations` rounds and return the elapsed nanoseconds.
///
/// `__volatile__` is load-bearing: without it the compiler deletes the whole loop
/// as dead code. `"cc"` declares that it clobbers the flags (`subs`).
static uint64_t probe_run(uint64_t iterations)
{
    uint64_t counter = iterations;
    uint64_t chain = 1;

    struct timespec start;
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    __asm__ __volatile__(
        "1:\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "add %0, %0, #1\n"
        "subs %1, %1, #1\n"
        "b.ne 1b\n"
        : "+r"(chain), "+r"(counter)
        :
        : "cc");

    clock_gettime(CLOCK_MONOTONIC, &end);

    // Consume the chain's final value so the compiler cannot decide the loop was
    // pointless. The value itself is of no interest — only the time it took.
    __asm__ __volatile__("" : : "r"(chain) : "memory");

    uint64_t seconds = (uint64_t)(end.tv_sec - start.tv_sec);
    uint64_t nanos = (uint64_t)(end.tv_nsec - start.tv_nsec);
    // tv_nsec can borrow (going 1.9 s -> 2.1 s changes both fields while the
    // difference is +0.2 s), so this is a sum, not a concatenation.
    return seconds * 1000000000ull + nanos;
}

/// Thread entry point: raise the QoS, then measure.
static void *probe_thread_main(void *context)
{
    // user-interactive puts this thread on a performance core and lifts the clock
    // there. The return value is ignored on purpose: if the QoS cannot be raised we
    // still measure, the reading is just more likely to come out low.
    (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);

    // Warm up until ~50 ms of wall time has elapsed, so the clock is fully ramped
    // before the measured rounds begin (see PROBE_WARMUP_TARGET_NS). Spinning in
    // chunks rather than a single fixed count is what makes this time-based.
    uint64_t warmed = 0;
    while (warmed < PROBE_WARMUP_TARGET_NS) {
        uint64_t chunk = probe_run(PROBE_WARMUP_CHUNK);
        if (chunk == 0) break;   // never expected; guards against a spin if the timer misbehaves
        warmed += chunk;
    }

    uint64_t best = 0;
    for (int round = 0; round < PROBE_MEASURE_ROUND_COUNT; round++) {
        uint64_t nanos = probe_run(PROBE_MEASURE_ROUNDS);
        if (nanos == 0) {
            continue;
        }
        // cycles / nanosecond == GHz; x1000 gives MHz.
        uint64_t cycles = (uint64_t)PROBE_MEASURE_ROUNDS * PROBE_UNROLL;
        uint64_t megahertz = cycles * 1000ull / nanos;
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

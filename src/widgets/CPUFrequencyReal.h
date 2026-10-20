//
//  CPUFrequencyReal.h
//  Helium
//
//  Reads the CPU's *actual* running clock out of IOReport — the same source
//  `powermetrics` uses — instead of the busy-loop probe's "peak achievable" figure.
//
//  See CPUFrequencyReal.mm for the full rationale and for the list of names that
//  still need verification on device.
//

#ifndef CPUFrequencyReal_h
#define CPUFrequencyReal_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Weighted-average clock of the performance cluster, in MHz, from IOReport's
/// per-state residency. Returns 0 whenever any step of the chain is unavailable
/// (symbols missing, subscription refused, DVFS table not found, all-idle sample)
/// so the caller can fall back to the busy-loop probe.
uint64_t helium_real_cpu_frequency_mhz(void);

/// Same reading, but **non-blocking**: it diffs against the previous sample instead
/// of sleeping 100 ms between two of them, so it is safe to call from a control loop
/// (see CPUFrequencyGovernor.mm). Returns the cached value when called more often
/// than the residency counters can produce a meaningful delta (~200 ms), and 0 when
/// the IOReport path is unavailable.
uint64_t helium_real_cpu_frequency_mhz_fast(void);

/// Highest gear in the performance cluster's DVFS table, in MHz — the value the
/// governor treats as "top". 0 when the table could not be read.
uint64_t helium_real_cpu_peak_mhz(void);

/// Human-readable report of what IOReport and the device tree actually expose on
/// this machine: every group/subgroup/channel that was enumerable, the state names
/// of the CPU Stats channels, and the DVFS tables that were found. Written to a
/// file so it can be read back without a debugger.
NSString *helium_real_cpu_frequency_diagnosis(void);

#ifdef __cplusplus
}
#endif

#endif /* CPUFrequencyReal_h */

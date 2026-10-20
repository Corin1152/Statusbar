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

/// Human-readable report of what IOReport and the device tree actually expose on
/// this machine: every group/subgroup/channel that was enumerable, the state names
/// of the CPU Stats channels, and the DVFS tables that were found. Written to a
/// file so it can be read back without a debugger.
NSString *helium_real_cpu_frequency_diagnosis(void);

#ifdef __cplusplus
}
#endif

#endif /* CPUFrequencyReal_h */

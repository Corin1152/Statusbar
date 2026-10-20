//
//  CPUFrequencyProbe.h
//  Helium
//
//  Measures the CPU's *current* clock with a cycle-counted busy loop.
//
//  Ported from SysProbe (Apache-2.0). See CPUFrequencyProbe.mm for why this has
//  to be measured rather than read.
//

#ifndef CPUFrequencyProbe_h
#define CPUFrequencyProbe_h

#include <stdint.h>

/// Current CPU frequency in MHz, or 0 when it could not be measured / the reading
/// was not plausible.
///
/// **This blocks for ~15-20 ms.** It runs a full-speed busy loop, so it must never
/// be called from the HUD's render path — sample it on a background queue and cache
/// the result. See the sampler in WidgetManager.mm.
uint64_t helium_measure_cpu_frequency_mhz(void);

#endif /* CPUFrequencyProbe_h */

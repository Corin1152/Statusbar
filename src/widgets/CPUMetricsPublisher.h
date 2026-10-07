//
//  CPUMetricsPublisher.h
//  Helium
//
//  Publishes Helium's CPU readings to a shared file so a second app on the same
//  device (SysProbe) can show the *same* numbers instead of sampling on its own.
//
//  See CPUMetricsPublisher.mm for the file format and the reasoning.
//

#ifndef CPUMetricsPublisher_h
#define CPUMetricsPublisher_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Starts the once-per-second publisher. Idempotent: calling it again is a no-op.
/// Safe to call from the HUD's main thread — the sampling happens on a private queue.
void helium_start_cpu_metrics_publisher(void);

#ifdef __cplusplus
}
#endif

#endif /* CPUMetricsPublisher_h */

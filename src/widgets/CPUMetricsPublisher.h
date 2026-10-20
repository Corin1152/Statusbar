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

/// Suspends / resumes the publisher. `paused == YES` stops the 1 Hz tick entirely;
/// resuming publishes once immediately, so the shared file is fresh the moment the
/// reader can look at it again.
///
/// Why this exists: the HUD's render timers are already paused while the screen is
/// locked (see `HUDRootViewController.pauseLoopTimer`), but the publisher was not —
/// so the device kept paying a busy-loop clock probe and a file write per second
/// to serve a Today view that cannot be on screen. Idempotent, and safe to call
/// before `helium_start_cpu_metrics_publisher` (the state is applied at start).
void helium_set_cpu_metrics_publisher_paused(BOOL paused);

#ifdef __cplusplus
}
#endif

#endif /* CPUMetricsPublisher_h */

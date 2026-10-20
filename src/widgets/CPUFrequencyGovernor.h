//
//  CPUFrequencyGovernor.h
//  Helium
//
//  A *test* feature: hold the performance cluster near its top gear by injecting
//  short busy pulses, instead of asking the kernel for a frequency (which iOS does
//  not expose — see CPUFrequencyReal.mm).
//
//  ## What this can and cannot do
//
//  It cannot set the clock. AppleARMCLPC is a closed-loop controller and the only
//  channel a user-space process has is *load*. So the governor does the only thing
//  that is possible: it makes the cluster busy for a controlled fraction of each
//  period, which is what CLPC reads as demand.
//
//  The consequence is unavoidable and is the point of the whole exercise: **a busy
//  cluster is a busy cluster**. The extra time shows up in CPU usage exactly as it
//  shows up in the frequency. There is no setting that produces clock without work.
//
//  ## Why pulses and not a permanent spin
//
//  A permanent two-core spin reaches the top gear and stays there, at 100 % of the
//  performance cluster, and heats the device until iOS thermal mitigation takes the
//  gear away again — the strategy cancels itself. Pulses trade a lower duty cycle
//  for a frequency that is *mostly* high: the cluster coasts on its own inertia
//  between pulses (CLPC's down-transition is not instant) and the average heat is
//  low enough that the mitigation never engages.
//
//  ## Guards (all of them stop the governor, not just lower it)
//
//    * thermal state serious/critical -> stop. This is the one that matters: on a
//      phone whose sustained performance is set by its chassis, continuing to push
//      after the mitigation has engaged makes the device *slower* than doing
//      nothing.
//    * Low Power Mode -> stop. LPM caps the cluster by design; fighting it burns
//      battery to lose.
//    * screen locked -> suspend. Nothing on screen can be smoother.
//
//  ## Measured feedback
//
//  Each pulse is gated on a real reading from IOReport: if the cluster is already
//  at (or near) its top gear, the pulse is skipped. Without that the governor would
//  be a fixed-duty heater that ignores whether it is achieving anything.
//

#ifndef CPUFrequencyGovernor_h
#define CPUFrequencyGovernor_h

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 0 = off, 1 = light (event priming + gentle pulses), 2 = strong (aggressive).
typedef NS_ENUM(int, HeliumGovernorMode) {
    HeliumGovernorModeOff = 0,
    HeliumGovernorModeLight = 1,
    HeliumGovernorModeStrong = 2,
};

/// Apply a mode. Idempotent; safe to call from any thread. Starts or stops the
/// worker threads as needed.
void helium_governor_apply(int mode);

/// Current mode (0 when off).
int helium_governor_mode(void);

/// One-shot pulse of `milliseconds` on the performance cluster, used to prime the
/// clock just before the user interacts (unlock, HUD reload). Ignored when the
/// governor is off or suspended.
void helium_governor_chirp(int milliseconds);

/// Suspend/resume without changing the mode — the HUD calls this on lock/unlock so
/// a locked screen costs nothing.
void helium_governor_suspend(BOOL suspended);

/// Human-readable state for the diagnostics screen:
/// mode, last measured clock, target, guard state, pulses fired/skipped.
NSString *helium_governor_status(void);

#ifdef __cplusplus
}
#endif

#endif /* CPUFrequencyGovernor_h */

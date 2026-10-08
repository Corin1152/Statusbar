# Helium
Status Bar Widgets for TrollStore iPhones on iOS 14+. Works on Jailbroken devices as well.

More widgets to come in future updates!

**Note:** on iOS 16+, you must enable developer mode for this to work properly.

## Building
[Theos](https://theos.dev) is required to compile the app. The SDK used is iOS 15.0, but you can use any SDK you want.
To change the SDK, go to the `Makefile` and modify the `TARGET` to your SDK version:
```
TARGET := iphone:clang:[SDK Version]:[Minimum Version]
```
Run `./ipabuild.sh` to build the ipa. The resulting tipa should be in a folder called 'build'.

## Tested Devices
- iPhone 13 Pro (iOS 15.3.1, Jailed & Jailbroken)
- iPhone X (iOS 16.1.1, Jailed & Jailbroken)
- iPhone X (iOS 16.6.1, Jailed)
- iPad 7th Generation (iOS 14.8.1, Jailed & Jailbroken)
- iPad 7th Generation (iOS 16.7.2, Jailbroken)

## Shared CPU metrics (contract with SysProbe)

The HUD (root, launched by a LaunchDaemon) publishes its CPU readings to a plain
file once a second, so a separate app on the same device — SysProbe — can show the
*same* numbers. There is no App Group and no XPC; the file is the entire interface.

    /var/tmp/cpu_metrics.json                        ← primary
    /var/mobile/Library/Caches/cpu_metrics.json      ← fallback, written only if the primary write fails

The reader tries the paths in that order and takes the first one that is present and
fresh, so the fallback exists for the setups where `/var/tmp` is not writable. It is
*not* written on every tick — until 0.25 both were written unconditionally, which
doubled the per-second file I/O to maintain a copy nothing ever read.

JSON:

    { "ts": <unix seconds, float>,   // the reader checks freshness against this
      "usage": <0..1, all-core average>,
      "per_core": [<0..1>, ...],
      "freq_mhz": <int>,             // 0 = no reading
      "freq_source": "ioreport" | "probe",
      "usage_mode": 0,
      "writer": "helium" }

**Changing any of it means changing both apps.** The reader is deliberately
forgiving — unknown keys are ignored, a missing file is not an error — so a
mismatch raises nothing at all; it just shows a wrong number or a dash. That covers
the key names and types, the units (0..1 not 0..100; MHz not Hz), the two paths and
the order they are tried in, and the freshness window the reader applies to `ts`.

Change `src/widgets/CPUMetricsPublisher.mm` and SysProbe's
`Sources/Shared/Hardware/CPUSharedMetrics.swift` together, and ship both apps
together. Both source files carry this same note.

Why a file rather than each app sampling for itself: two busy-loop clock probes
fight over the same performance cores and drag each other's readings down, and two
offset usage samplers can never agree on a number — which is the whole point of the
exercise.

## Per-second cost (and what 0.25 removed)

The HUD runs for as long as the device is up, so everything it does *per second* has
to be justified. Three pieces of work were not:

**The publisher kept running while the screen was locked.** Locking already paused the
render timers (`HUDRootViewController.pauseLoopTimer`), but not the 1 Hz publisher —
so the device kept paying a busy-loop clock probe and a file write per second to serve
a Today view that cannot be on screen. `helium_set_cpu_metrics_publisher_paused` now
follows the lock state, and resuming publishes once immediately: the reader's freshness
window is 5 s, so without that catch-up tick the first read after unlocking could land
on a file that had just expired and show a dash while the status bar showed a number.

**The fallback path was written every second for nothing.** See the section above.

**A cancelled timer kept firing.** `EZTimer.cancel:` used to keep
`dispatch_source_cancel` inside the "source is suspended" branch. A suspended source
does have to be resumed before it can be released — but as written, cancelling a
*running* timer only removed it from the timer dictionary, leaving the source firing on
its own interval with no name left to stop it. Nothing crashed; a disabled widget just
kept running `updateLabel:` (a text layout plus a `dispatch_sync` back to the main
queue) every second, drawing into a hidden label, and re-enabling it added a second
source on top. `cancel` is now unconditional.

Deliberately *not* changed: the `nanosleep(100 ms)` in
`helium_real_cpu_frequency_mhz`. It sits at the end of that path, after
`ensureFreqSubscription()` — which is refused on this device, so the call returns
early and never reaches it. When it *is* reached, the result is used as `freq_mhz` with
`freq_source = "ioreport"`. Either it is not reached or it is not wasted. The reasoning
is in the source next to the call.

## Credits
- [TrollSpeed](https://github.com/Lessica/TrollSpeed) for the AssistiveTouch logic allowing this to work.
- [Cowabunga](https://github.com/leminlimez/Cowabunga) for part of the code.
- [AsakuraFuuko](https://github.com/AsakuraFuuko) for forking and updating.
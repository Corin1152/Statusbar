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

## Per-tick cost (and what 0.26 removed)

The HUD runs for as long as the device is up, so everything it does on the render path
has to be justified. It turned out that a fair amount of it was not — not one big thing,
but several small ones stacked on the same main-thread pass, which is what "the device
feels laggy with the HUD on" actually is.

**One timer per widget, where one per set is enough.** `updateInterval` is a property of
the *set* (`WidgetSetStruct.updateInterval`), so every widget in a set shares an interval
and has no reason to own a `dispatch_source`. Each one was started with its own
`dispatch_walltime(NULL, 0)` and its own phase, with a 10 % leeway — so the wake-ups
never lined up. A set of four widgets meant four main-thread wake-ups per period, four
rounds of "CoreText layout + frame resize + mask reset", four CA commits. One timer per
set makes it one. It also means the widgets in a set are sampled on the *same* main-thread
pass, which is what makes the caches below actually hit.

**`updateLabel` drew both render paths, and only one of them is ever visible.**
`reloadUserDefaults` guarantees exactly one of them at a time: with adaptive colour on
(the default) the visible one is the backdrop + maskLabel and `label` is hidden; with it
off, the other way round. Writing both cost a different price on each side — writing
`label` invalidates its `intrinsicContentSize`, so all ~6N constraints on `_contentView`
had to be solved again, and writing `maskLabel` swaps the `CABackdropLayer`'s mask, and
that layer carries five `CAFilter`s (a 50 pt gaussian blur plus brightness, contrast,
saturate and invert), so the mask changing forces a re-composite. In the default
configuration the visible side is the backdrop one, which means every widget was
*additionally* triggering a full Auto Layout pass per tick, into a label nobody could see.

**CPU temperature was sampled on the render path.** The fast path of
`getCPUDieTemperature()` enumerates every AppleVendor temperature service, two IOKit
round-trips each (`CopyProperty` + `CopyEvent`) — dozens of them on an A11. That is a
synchronous kernel enumeration, and it ran on the main thread every tick. It now works
the same way the CPU clock does: a background serial queue samples and caches (1 s), and
the formatter only reads the cache. The very first sample after boot is still taken
synchronously, so the widget does not flash `??ºC` once on launch.

**Battery properties were re-read up to four times per tick.** The device-temperature,
battery-detail, battery-percentage and charging-symbol widgets all want the same
`IOPMPowerSource` dictionary, and each called `getBatteryInfo()` (two IOKit round-trips)
independently. Now cached for 0.25 s. Same for the tinted charging-symbol bitmap —
`imageWithTintColor:` is a real rasterisation and it was redone every tick.

**The clock probe ran even when nothing displayed it.** The probe saturates both
performance cores for ~62 ms at `QOS_CLASS_USER_INTERACTIVE` — which means it preempts
the foreground; that is not an accident, it is the only way to get CLPC to grant the top
gear. But the publisher kicked it every second unconditionally, so the device paid a
double-core stall every 5 s even with no CPU-frequency widget anywhere on the HUD. It is
now gated on `HeliumCPUFrequencyWidgetInUse()` — "somebody actually drew this number in
the last 10 s". The shared file's format is unchanged; when nobody is looking `freq_mhz`
is written as 0, and SysProbe falls back to sampling on its own, which it already did.

**`NOTIFY_RELOAD_HUD` was delivered twice.** It is registered twice — once via
`notify_register_dispatch` and once via `CFNotificationCenterAddObserver` on the Darwin
centre — and `notify_post` feeds both. So every settings change ran "read defaults +
reschedule timers + rebuild every constraint" twice. There is now a 200 ms de-duplication
window, which is more robust than betting on which registration path is the reliable one.

Deliberately *not* changed:

* The probe's 5 s throttle. If you *do* keep a CPU-frequency widget on screen, that
  62 ms double-core stall every 5 s is the remaining visible hitch, and it is inherent to
  measuring the top gear. Removing the widget is now enough to stop it entirely.
* Adaptive colour's default of on. It is a `CABackdropLayer` with a 50 pt gaussian blur;
  turning it off is a straight win if you do not need the tinted look, but it is a
  visible appearance change, so it stays the user's call.

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
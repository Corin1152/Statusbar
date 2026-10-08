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
    /var/mobile/Library/Caches/cpu_metrics.json      ← survives a reboot

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

## Credits
- [TrollSpeed](https://github.com/Lessica/TrollSpeed) for the AssistiveTouch logic allowing this to work.
- [Cowabunga](https://github.com/leminlimez/Cowabunga) for part of the code.
- [AsakuraFuuko](https://github.com/AsakuraFuuko) for forking and updating.
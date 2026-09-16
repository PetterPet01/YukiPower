# YukiPower

A rootless Control Center module for Dopamine/iOS 15 that toggles a battery-emergency profile:

**Ultra ON**
- Enables native iOS Low Power Mode.
- Sets Powercuff `PowerMode=4` (Heavy).
- Sets Powercuff `RequireLowPowerMode=false` so throttling stays active independently.
- Reads every tweak `.dylib` currently installed under `/var/jb/Library/MobileSubstrate/DynamicLibraries` and temporarily adds it to Choicy's `globalDeniedTweaks` list.
- Explicitly keeps Powercuff, Choicy, CCSupport, ChoicySB/MobileSafety and supporting loader dylibs allowed.
- Saves your prior Choicy list, Powercuff settings, and LPM state first.
- Resprings SpringBoard once so the new injection policy actually takes effect.

**Ultra OFF**
- Restores the previous Choicy global-deny key exactly (including key absence).
- Restores previous Powercuff values, including absent keys.
- Restores the previous iOS Low Power Mode state.
- Resprings again.

## Requirements

- Dopamine/rootless jailbreak on iOS 15.x.
- CCSupport (`com.opa334.ccsupport`).
- Choicy (`com.opa334.choicy`).
- Powercuff package using the original identifier `com.rpetrich.powercuff`.

Designed for the user's iPhone 7 on iOS 15.7.3. `ARCHS=arm64`, deployment target 15.0.

## Install after building

1. Install the generated `iphoneos-arm64.deb` in Sileo/Zebra/Filza.
2. Respring if your package manager does not do so automatically.
3. Open **Settings > Control Center** and add **YukiPower**.
4. Tap once to enter Ultra; SpringBoard resprings and the tile should return selected.
5. Tap again to restore; SpringBoard resprings again.

## Important safety / recovery notes

- **Turn Ultra OFF before uninstalling YukiPower.** The saved Choicy deny-list is a preference change and is intentionally persistent across resprings.
- If the tile is unavailable while Ultra is active, open Choicy's preferences and clear/restore its **Global Tweak Configuration**, then respring. The backup remains at `/var/mobile/Library/Preferences/com.yukipower.state.plist` for manual recovery in Filza.
- If a tap still does nothing, NewTerm: `log stream --predicate 'eventMessage CONTAINS "YukiPower"' --level debug`. A working tap logs `[YukiPower] setSelected:1` then a respring.
- This disables injection for newly launched processes and gives SpringBoard a clean reload. It does not forcibly terminate every already-running app/daemon.
- If a future Choicy release changes its preference schema, verify `globalDeniedTweaks` before using YukiPower.
- The Powercuff rootless recompile is unofficial; Heavy is intentionally aggressive and may make the phone feel slow.

## Local build

With Theos + an iOS SDK + a Linux iOS toolchain:

```bash
export THEOS=$HOME/theos
./scripts/build-linux.sh
```

The output is placed in `packages/`.

## GitHub Actions build

Every push to `main` (and **Actions > Build YukiPower > Run workflow**) produces a rootless `iphoneos-arm64` `.deb`.

- **Release (easiest):** [Releases → Latest build](https://github.com/PetterPet01/YukiPower/releases/latest)
- **Artifact:** **Actions > Build YukiPower** → `YukiPower-rootless`

## Implementation notes

The Control Center interface follows Theos' CCSupport module layout (`CCUIToggleModule`). Choicy's `globalDeniedTweaks` entries are tweak dylib basenames, which is why YukiPower scans the actual DynamicLibraries directory instead of keeping a hard-coded list of your cosmetic tweaks.

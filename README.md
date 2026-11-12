# Vedimac

A native macOS menu-bar item and dashboard for Apple silicon MacBooks that use a charge limit.
It shows what the battery is doing, records history, checks the five battery-gauging values after
restarts and macOS updates, and can reapply or roll back the experimental workaround on demand.

> **Status of this release (1.0.3).** A first build on the target Mac (macOS 27.2 SDK, Command
> Line Tools only) compiled the plist library and the helper, and failed in the app only where it
> used `@State` and in the tests only because of XCTest. Both are removed in this version. The
> fixed source has **not been compiled again**, because no Swift toolchain is available where it
> was written. See [What has been verified](#what-has-been-verified).

## Build and install

Requirements: macOS 14 or later on Apple silicon, and the Xcode Command Line Tools
(`xcode-select --install`). Full Xcode is not needed.

Run these one at a time, from the project folder:

```bash
cd ~/Downloads/ChargeWatch
Scripts/test.sh
Scripts/build-app.sh
Scripts/package-dmg.sh
open dist/Vedimac-1.0.3.dmg
```

`Scripts/test.sh` runs the fixture checks and must end with `ALL PASSED`. It never touches the
system file and never restarts the Mac. `build-app.sh` creates `dist/Vedimac.app`;
`package-dmg.sh` creates the disk image.

Drag Vedimac to Applications and open it. A battery item appears in the menu bar and the
dashboard opens.

**Signing.** By default the build is **ad-hoc signed and not notarized**. That is fine on the Mac
that built it. On another Mac, Gatekeeper will block it. To sign and notarize with your own
Developer ID:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build-app.sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/package-dmg.sh
xcrun notarytool submit dist/Vedimac-1.0.3.dmg --keychain-profile "notary" --wait
xcrun stapler staple dist/Vedimac-1.0.3.dmg
```

## Using it

### See what the battery is doing
The menu-bar item shows an icon and the percentage: a bolt while charging, a plug while plugged in
without charging, a battery while on battery. The Overview page states the two facts separately,
**Power adapter: Connected / Not connected** and **Battery: Charging / Not charging**. Every reading
carries a tag for where it comes from (public API, private registry key, calculated, your setting),
and missing readings say "Not available".

The Charge Limit is **your reference setting**, 80% by default. macOS has no public interface for
reading it. Change it on the Overview page to match System Settings.

### Check after an update or restart
Vedimac remembers the last macOS build and boot time. When either changes, a banner offers
**Check after update** or **Check after restart**. **Check now** on the Calibration page does the
same at any time. macOS asks for an administrator password, because the file is readable only by
root. The result is one of:

| Result | Meaning |
|---|---|
| Full match | All five values are as expected |
| Partial rewrite | Some values changed (for example only `lastDOD0Update`) |
| Full mismatch | None of the five match |
| Unreadable or unsupported | The file is missing, a symlink, or has a schema the app does not recognise |

The battery state at the moment of the check is recorded next to it. They are separate
observations and are always shown side by side.

### Reapply the workaround
1. Press **Reapply calibration workaround**. A preview lists exactly which values would change,
   current → expected. If all five match it says so and nothing is written.
2. Choose **Apply** or **Apply and Restart**. Nothing is written before this.
3. The helper validates the schema, makes and verifies a backup, changes only the differing keys,
   re-checks that the live file is still the one you previewed, and replaces it atomically.

**Apply and Restart restarts immediately** (`shutdown -r now`) without asking apps to save. Save
your work first. After the restart, open Vedimac and press **Verify after restart**: it reports
whether all five values persisted and, separately, whether the battery is charging.

Expect two password prompts when the last check is more than five minutes old: one for the
preview, one for the write.

### Restore a backup
On the Calibration page, each backup has **Restore…**. The preview shows the values in that backup,
its date, build and checksum, and warns if it was made on a different macOS build. **Restore** or
**Restore and Restart** then verifies the backup's checksum and schema, saves the current file as a
new backup, and puts the selected one back byte for byte.

Use **Import original backup…** to bring in the backup your Terminal script made on 6 November. It
is validated, copied into the protected folder, and marked as the original pre-workaround backup.

### Export diagnostics
**Export & settings** offers the battery history (CSV), the events (CSV) and a diagnostic report
(Markdown). Redaction is on by default: home paths, your user name and serial-like identifiers are
removed. The battery serial is never read, and the battery pack identifier only appears as a hash.

## Where things are stored

| What | Where |
|---|---|
| History, events, settings | `~/Library/Application Support/ChargeWatch/` |
| Plist backups (root only) | `/Library/Application Support/ChargeWatch/Backups/` |
| Backup list and last operation | `/Library/Application Support/ChargeWatch/manifest.json`, `last-operation.json` |

Vedimac makes no network connections.

## How the privileged part works

Only `gaugectl` (in `Contents/Helpers`) ever runs as root, and only for four commands: `status`,
`apply`, `restore`, `import-original`. As root it works on one fixed file and one fixed backup
folder; the paths cannot be overridden. The app starts it through the standard macOS administrator
dialog (`do shell script … with administrator privileges`), so the password is handled by macOS
and never reaches the app, a log or a script.

One thing to know: because the helper lives inside the app bundle and is not a notarized,
separately installed daemon, anything able to modify `/Applications/Vedimac.app` could replace
it before you authenticate. Keep the app in `/Applications` and build it yourself. A hardened
version would install the helper with `SMAppService` under a Developer ID.

## What has been verified

| | Status |
|---|---|
| Fixture files parse and contain the intended states | **Checked** here with Python's `plistlib` |
| Plist library (`GaugeCore`) and helper (`gaugectl`) compile and link | **Seen** in the first build log from the target Mac |
| App compiles | **Not confirmed.** The first build reported errors only for `@State`; those uses are gone, the result has not been rebuilt |
| Fixture checks (`Scripts/test.sh`) pass | **Not run.** The check program is new in 1.0.3 and has not been compiled |
| Anything on a real Mac: battery readings, the administrator dialog, reading or writing the real plist, restart, verification after boot | **Not verified** |

The fixture checks cover: the original state, all five values applied, and the post-update state
with only `lastDOD0Update` changed, each in binary and XML; invalid schemas (two packs, wrong pack
count, missing key, wrong value types, missing root key, corrupt file); a symlink; a concurrent
change during apply and during restore; a stale preview; restoring a verified backup; refusing a
damaged or incompatible backup; and importing the original backup. They work on copies in a
temporary folder. The library they test contains no restart code, and the helper refuses to touch
the system file unless it runs as root.

The fixtures are synthetic. They follow the schema you described, with an invented pack identifier
and invented extra keys.

## Assumptions to check on your Mac

- **`batteryPackCount` location.** The helper looks for it inside `batteryGaugingMitigationInfo`,
  then at the root of the plist. If your file keeps it elsewhere, the check will stop with
  "batteryPackCount is missing" and nothing will be written. Tell me where it is.
- **Registry keys.** Cycle count, capacities, temperature, voltage and current come from
  undocumented `AppleSmartBattery` keys (`CycleCount`, `AppleRawMaxCapacity`, `DesignCapacity`,
  `Temperature`, `Voltage`, `Amperage`). Compare them once with `ioreg -rn AppleSmartBattery`.
- **Gauging detection.** A "confirmed gauging charge" event is recorded when the battery is
  charging while the registry or `pmset -g batt` reports a string containing "gauging" (such as
  `ChargingUpForGauging`). Where macOS 27 reports that state has not been confirmed.
- **powerd messages.** Read with `log show` as your user. If that returns nothing, run the same
  command in Terminal to see whether your account can read the log.

The workaround itself is unsupported. It may affect battery percentage or capacity estimates, and
the timestamps do not schedule the next calibration.

## Project layout

```
Sources/GaugeCore/     plist validation, comparison, apply, backup, restore (no UI, no restart)
Sources/gaugectl/      the root helper
Sources/Vedimac/   menu-bar item and dashboard (SwiftUI, Swift Charts, IOKit)
Sources/gaugecheck/    fixture checks as a plain program (no XCTest)
Tests/Fixtures/        anonymized binary and XML fixtures
Scripts/               build-app.sh, package-dmg.sh, test.sh, make-fixtures.py
```

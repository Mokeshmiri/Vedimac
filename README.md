# Vedimac

**Battery health, power flow, and charging history in your Mac’s menu bar.**

Vedimac is a free, open-source battery monitor for Apple silicon MacBooks. View detailed battery readings, track changes over time, and export diagnostics when investigating charging problems.

Built after investigating why macOS sometimes ignored the native charge limit, Vedimac also includes an experimental battery-gauging workaround with preview, backup, and restore.

[Download the latest release](https://github.com/Mokeshmiri/Vedimac/releases/latest) · [Report a bug](https://github.com/Mokeshmiri/Vedimac/issues)
<img width="1280" height="949" alt="Screenshot 2026-11-19 at 3 15 34 PM copy" src="https://github.com/user-attachments/assets/6be9664e-3325-44b4-9a9d-e9531a839c58" />


## Features

| Feature | What you get |
| --- | --- |
| Charging status | Battery percentage, adapter connection, and estimated charging time |
| Battery health | macOS-reported condition and maximum capacity, raw health calculation, cycle count, and capacity readings |
| Power readings | Battery voltage, current, and calculated power |
| Adapter details | Adapter name, rated power, voltage, and current |
| History | Charts of battery readings over time |
| Diagnostic exports | CSV history, events, and a diagnostic report with privacy redaction |
| Reference charge limit | A reference line for charts and an indication when charging exceeds your chosen value |
| Experimental calibration tools | Inspect and preview a battery-gauging workaround, with backup and restore |

Some measurements depend on what your Mac reports. Unavailable readings are labeled in the dashboard.

## Install

### Requirements

- An Apple silicon MacBook, M1 or newer
- macOS 14 Sonoma or newer

### Homebrew

Run this command in Terminal:

```bash
brew install --cask mokeshmiri/tap/vedimac
```

Open **Vedimac** from your Applications folder. A battery icon appears in the menu bar.

### Download the app

1. Open the [latest release](https://github.com/Mokeshmiri/Vedimac/releases/latest).
2. Download the Vedimac ZIP file.
3. Extract it and move **Vedimac.app** to **Applications**.
4. Open the app.

### First launch

Vedimac currently uses an ad hoc signature. macOS may block the app on first launch.

Review the project and release information before approving it. If macOS offers the option, you can approve opening the app through **System Settings → Privacy & Security → Open Anyway**.

### Build from source

Building requires Xcode Command Line Tools. Install them if needed:

```bash
xcode-select --install
```

Clone the repository and build:

```bash
git clone https://github.com/Mokeshmiri/Vedimac.git
cd Vedimac
Scripts/build-app.sh
open dist/Vedimac.app
```

Move the built app from `dist` to **Applications** to keep it installed.

## Use Vedimac

Click the battery icon in the menu bar for a quick view, then choose **Open Dashboard** for more detail.

| View | Purpose |
| --- | --- |
| Overview | Charging status, battery health, power readings, adapter details, and workaround status |
| History | Battery readings over time |
| Calibration | Experimental workaround checks, previews, and backups |
| Export & settings | Diagnostic exports and app settings |

Vedimac records history about once a minute while running. Enable **Open at login** if you want it to start recording after you sign in.

### Understand battery health

The Overview shows both macOS-reported maximum capacity and a raw health calculation.

The raw calculation divides the reported full-charge capacity by design capacity. Apple calculates its maximum-capacity figure differently, so the two percentages can differ.

The dashboard labels readings by their source, including system reports, public APIs, private keys, and calculated values.

### Set your reference charge limit

Set Vedimac’s reference limit to match the charge limit you selected in **System Settings → Battery**.

Vedimac uses this reference value for its chart line and to flag charging more than three percentage points above it. Changing the reference value in Vedimac does not change the macOS charging limit.

### Export diagnostics

Use **Export & settings** to save history or a diagnostic report.

Enable **Redact** before sharing exports, then review the resulting files for personal information.

## Experimental battery-gauging workaround

> This feature modifies a macOS system file used for battery gauging. Changes can affect charge reporting and battery behavior beyond Vedimac. Long-term effectiveness is uncertain, and the original charging issue may return.

Some users have reported that macOS enters a battery-gauging state and overrides their configured charge limit. Vedimac includes tools for inspecting and applying a workaround related to that state.

The feature requires administrator permission and includes a preview, backup, verification, and restore process. Backups provide a recovery path, but cannot guarantee every outcome on every Mac.

The monitoring, history, and export features can be used independently of this workaround.

### Apply the workaround

1. Open **Calibration** and press **Check**.
2. Read the result and preview the proposed changes.
3. Review the risks before continuing.
4. Press **Apply** and approve the administrator prompt.
5. Save your work and restart your Mac.
6. Open Vedimac and press **Verify after restart**.
7. Monitor charging behavior over the following days.

### Understand verification

A matching result means the checked values match the workaround’s expected values. Charging behavior still needs to be observed over time.

### Restore a backup

Open **Calibration**, press **Restore**, and select the backup you want to restore.

Vedimac checks the backup before restoring it. Follow the app’s instructions to complete the process.

### Background

The investigation that helped inform this project is documented in the AlDente community’s discussion of macOS battery calibration overriding charge limits.

[Read the discussion](https://github.com/AppHouseKitchen/AlDente-Battery_Care_and_Monitoring/issues/1846)

## Update

Quit Vedimac before replacing the installed app.

### Homebrew

```bash
brew update
brew upgrade --cask mokeshmiri/tap/vedimac
```

### Downloaded app

Download the newest ZIP from the [releases page](https://github.com/Mokeshmiri/Vedimac/releases/latest), extract it, and replace the app in **Applications**.

### Built from source

From your local repository:

```bash
git pull
Scripts/build-app.sh
```

Replace the installed app with the newly built copy from `dist`.

## Uninstall

If you applied the experimental workaround and want to undo it, use **Restore** while Vedimac is still installed. Complete the restoration before removing the app.

Then quit Vedimac.

For a Homebrew installation:

```bash
brew uninstall --cask mokeshmiri/tap/vedimac
```

For a manual installation, delete **Vedimac.app** from **Applications**.

Removing the app leaves saved data and calibration backups on disk. Keep any backups you may need for recovery.

## Data and privacy

Vedimac processes battery data locally. Exported files are saved for you to review and share.

| Data | Location |
| --- | --- |
| History, events, and settings | `~/Library/Application Support/ChargeWatch/` |
| Calibration backups, administrator access required | `/Library/Application Support/ChargeWatch/Backups/` |
| Backup manifest | `/Library/Application Support/ChargeWatch/manifest.json` |

The storage folders retain the original **ChargeWatch** name so existing data and backups remain accessible.

Review diagnostic exports before posting them publicly, even when redaction is enabled.

## Report a problem

Please include the following details in a GitHub issue.

- MacBook model and chip
- macOS version
- Vedimac version
- Whether the battery is original or replaced
- What you expected and what happened
- Steps to reproduce the problem
- Relevant screenshots or redacted diagnostics

For charging issues, include your configured macOS charge limit, Vedimac’s reference limit, and whether the experimental workaround has been applied.

[Open an issue](https://github.com/Mokeshmiri/Vedimac/issues)

## Development

Vedimac uses Swift and SwiftUI.

```text
Sources/
├── GaugeCore/      Battery-gauging logic, backups, and checked writes
├── gaugectl/       Administrator tool for calibration operations
├── ChargeWatch/    Menu-bar app and SwiftUI dashboard
└── gaugecheck/     Automated checks
```

Run the checks:

```bash
swift run gaugecheck
```

Or use the project script:

```bash
Scripts/test.sh
```

Build the app:

```bash
Scripts/build-app.sh
```

Bug reports, reproducible test results, and focused pull requests are welcome. For larger changes, open an issue first to discuss the approach.

## Support the project

If Vedimac is useful to you, consider starring the repository.

Testing on different MacBook models, reporting bugs, and sharing diagnostic results also help improve the app.

## License

Vedimac is released under the [MIT License](LICENSE).

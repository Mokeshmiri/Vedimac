import Foundation
import SwiftUI
import GaugeCore

@MainActor
final class AppModel: ObservableObject {

    // Live
    @Published private(set) var reading = BatteryReading(timestamp: Date())
    @Published private(set) var pmsetText = ""
    private var systemReport = SystemReportBattery()

    // Recorded
    @Published var persisted: PersistedState
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var events: [DiagnosticEvent] = []

    // Calibration
    @Published private(set) var backups: [BackupEntry] = []
    @Published private(set) var lastHelperOperation: OperationResult?
    @Published private(set) var powerd = PowerdSnapshot()
    @Published private(set) var busy: String?
    @Published var alert: AlertMessage?
    @Published var section: DashboardSection? = .overview

    // View state lives here as plain @Published properties. SwiftUI's @State is a compiler macro
    // in recent SDKs whose plugin ships only with Xcode, so it does not build with the
    // Command Line Tools alone.
    @Published var applyPreview: ApplyPreview?
    @Published var restoreCandidate: BackupEntry?
    @Published var historyRange: HistoryRange = .day
    @Published var redactExports = true
    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var showInDock = DockPresence.showInDock

    func setShowInDock(_ value: Bool) {
        DockPresence.save(value)
        showInDock = value
    }

    let build = SystemInfo.build
    let osVersion = SystemInfo.version
    let bootTime = SystemInfo.bootTime

    private let history = HistoryStore()
    private let systemStore = BackupStore(directory: BackupStore.systemDirectory)
    private var timer: Timer?
    private var tickCount = 0
    private var lastSample: Sample?
    private var gaugingEpisodeRecorded = false
    private var gaugingHintRecorded = false
    private var aboveLimitEpisodeRecorded = false

    init() {
        persisted = HistoryStore().loadState()
        samples = history.loadSamples()
        events = history.loadEvents()
        lastSample = samples.last
        reloadBackups()
        detectSystemChanges()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: Derived state

    var lastCheck: CheckRecord? { persisted.checks.last }

    var lastSuccessfulCheck: CheckRecord? {
        persisted.checks.last { $0.outcome != .unreadable }
    }

    /// True when a gauging state is being reported right now, by the registry or by pmset.
    var gaugingStateReported: Bool {
        reading.gaugingStateInRegistry || BatteryReader.mentionsGauging(pmsetText)
    }

    var originalBackup: BackupEntry? {
        backups.first { $0.kind == .importedOriginal }
    }

    // MARK: Sampling

    private func tick() {
        var current = BatteryReader.read()
        if current.condition == nil { current.condition = systemReport.condition }
        current.appleMaximumCapacityPercent = systemReport.maximumCapacityPercent
        reading = current
        tickCount += 1

        if tickCount % 12 == 1 { refreshPmset() }
        if tickCount % 120 == 1 { refreshSystemReport() }
        recordSampleIfNeeded(current)
        detectChargingEpisodes(current)
    }

    private func refreshSystemReport() {
        Task.detached(priority: .utility) {
            let report = SystemReportBattery.read()
            await MainActor.run {
                self.systemReport = report
                self.reading.condition = self.reading.condition ?? report.condition
                self.reading.appleMaximumCapacityPercent = report.maximumCapacityPercent
            }
        }
    }

    private func refreshPmset() {
        Task.detached(priority: .utility) {
            let output = Shell.run("/usr/bin/pmset", ["-g", "batt"], timeout: 10)
            let text = output.status == 0 ? output.out : ""
            await MainActor.run { self.pmsetText = text }
        }
    }

    private func recordSampleIfNeeded(_ current: BatteryReading) {
        guard current.hasBattery, let percent = current.percent, let ac = current.acConnected else { return }
        let sample = Sample(t: current.timestamp, pct: percent, ac: ac, chg: current.isCharging ?? false)
        if let last = lastSample {
            let changed = last.pct != sample.pct || last.ac != sample.ac || last.chg != sample.chg
            let due = sample.t.timeIntervalSince(last.t) >= 60
            guard changed || due else { return }
        }
        lastSample = sample
        samples.append(sample)
        history.append(sample)
    }

    /// Records charging-related observations. A "confirmed" gauging charge needs two things at the
    /// same moment: the battery is actually charging, and macOS reports a gauging state.
    private func detectChargingEpisodes(_ current: BatteryReading) {
        let charging = current.state == .charging
        let percentText = current.percent.map { "\($0)%" } ?? "unknown level"

        if gaugingStateReported {
            var hint = "gauging state"
            if let registryHint = current.gaugingHints.first {
                hint = registryHint
            } else if let line = pmsetText.split(separator: "\n").first(where: { BatteryReader.mentionsGauging(String($0)) }) {
                hint = "pmset: " + line.trimmingCharacters(in: .whitespaces)
            }
            if charging {
                if !gaugingEpisodeRecorded {
                    gaugingEpisodeRecorded = true
                    addEvent(.calibrationConfirmed,
                             "Charging at \(percentText) while macOS reported: \(hint)",
                             source: "IOPowerSources + AppleSmartBattery registry / pmset -g batt")
                }
            } else if !gaugingHintRecorded {
                gaugingHintRecorded = true
                addEvent(.gaugingHint,
                         "\(hint). Battery was \(current.state.title.lowercased()) at \(percentText), so this is not a confirmed gauging charge.",
                         source: "AppleSmartBattery registry / pmset -g batt")
            }
        } else {
            gaugingHintRecorded = false
        }
        if !charging { gaugingEpisodeRecorded = false }

        // Charging clearly above the reference limit, without any reported reason.
        if charging, let percent = current.percent, percent >= persisted.limitPercent + 3 {
            if !aboveLimitEpisodeRecorded {
                aboveLimitEpisodeRecorded = true
                let reason = gaugingStateReported ? "A gauging state was reported." : "No gauging state was reported at that moment."
                addEvent(.chargeAboveLimit,
                         "Charging at \(percent)% with the reference limit at \(persisted.limitPercent)%. \(reason)",
                         source: "IOPowerSources")
            }
        } else if !charging {
            aboveLimitEpisodeRecorded = false
        }
    }

    // MARK: Builds, restarts, pending verification

    private func detectSystemChanges() {
        if let last = persisted.lastSeenBuild, last != build {
            addEvent(.buildChange, "\(last) → \(build) (macOS \(osVersion))", source: "sysctl kern.osversion")
            persisted.checkPrompt = CheckPrompt(reason: .buildChange,
                                                detail: "macOS changed from build \(last) to \(build). Check whether the five values were rewritten.",
                                                date: Date())
        }
        persisted.lastSeenBuild = build

        if let boot = bootTime {
            if let lastBoot = persisted.lastSeenBoot, abs(boot.timeIntervalSince(lastBoot)) > 120 {
                addEvent(.restart, "Started up \(Fmt.dateTime(boot))", source: "sysctl kern.boottime", date: boot)
                if persisted.checkPrompt == nil {
                    persisted.checkPrompt = CheckPrompt(reason: .restart,
                                                        detail: "The Mac restarted. powerd can rewrite the values at boot.",
                                                        date: Date())
                }
            }
            persisted.lastSeenBoot = boot
        }

        if var pending = persisted.pending {
            // The app may have been closed by the restart before it saw the helper's answer.
            if !pending.confirmed {
                if let operation = lastHelperOperation, operation.wroteFile,
                   operation.finishedAt >= pending.requestedAt.addingTimeInterval(-5) {
                    pending.confirmed = true
                    pending.expected = operation.after.keys
                    persisted.pending = pending
                } else {
                    persisted.pending = nil
                }
            }
            if let confirmed = persisted.pending, let boot = bootTime, boot > confirmed.requestedAt {
                persisted.checkPrompt = CheckPrompt(reason: .verify,
                                                    detail: "The Mac restarted after the \(confirmed.kind == "apply" ? "workaround was applied" : "backup was restored"). Verify whether all five values persisted.",
                                                    date: Date())
            }
        }
        save()
    }

    // MARK: Events and persistence

    private func addEvent(_ kind: EventKind, _ detail: String, source: String, date: Date = Date()) {
        events.append(DiagnosticEvent(date: date, kind: kind, detail: detail, source: source))
        if events.count > 2_000 { events.removeFirst(events.count - 2_000) }
        history.saveEvents(events)
    }

    func save() {
        if persisted.checks.count > 100 { persisted.checks.removeFirst(persisted.checks.count - 100) }
        history.saveState(persisted)
    }

    func setLimit(_ value: Int) {
        persisted.limitPercent = min(100, max(50, value))
        save()
    }

    func reloadBackups() {
        backups = ((try? systemStore.loadManifest())?.entries ?? []).sorted { $0.createdAt > $1.createdAt }
        lastHelperOperation = systemStore.loadLastOperation()
    }

    // MARK: Helper calls

    private func runHelper(_ arguments: [String], prompt: String, status: String) async -> Result<HelperResponse, Error> {
        busy = status
        defer { busy = nil }
        return await Task.detached(priority: .userInitiated) {
            Result { try PrivilegedHelper.run(arguments, prompt: prompt) }
        }.value
    }

    private func isCancellation(_ error: Error) -> Bool {
        if let helperError = error as? HelperError, case .cancelled = helperError { return true }
        return false
    }

    /// Reads and validates the five values. Returns the report when the file was readable.
    @discardableResult
    func checkNow(trigger: String) async -> CheckReport? {
        let result = await runHelper(["status"],
                                     prompt: "Vedimac needs administrator access to read the battery-gauging settings.",
                                     status: "Reading the five values…")
        let battery = reading
        var report: CheckReport?

        switch result {
        case .failure(let error):
            if isCancellation(error) { return nil }
            alert = AlertMessage(title: "Check failed", message: error.localizedDescription)
            return nil
        case .success(let response):
            if response.ok, let received = response.report {
                report = received
                recordCheck(received, trigger: trigger, battery: battery)
            } else {
                let message = response.errorMessage ?? "The file could not be read."
                persisted.checks.append(CheckRecord(date: Date(), build: build, trigger: trigger,
                                                    outcome: .unreadable, report: nil, errorMessage: message,
                                                    batteryPercent: battery.percent, powerState: battery.state))
                addEvent(.check, "Unreadable or unsupported: \(message)", source: "gaugectl status")
                save()
                alert = AlertMessage(title: "The file could not be checked", message: message)
            }
        }
        await refreshPowerd()
        return report
    }

    private func recordCheck(_ report: CheckReport, trigger: String, battery: BatteryReading) {
        let record = CheckRecord(date: report.checkedAt, build: build, trigger: trigger,
                                 outcome: CheckOutcome(report.state), report: report, errorMessage: nil,
                                 batteryPercent: battery.percent, powerState: battery.state)
        persisted.checks.append(record)
        persisted.checkPrompt = nil
        addEvent(.check, "\(record.outcome.title). \(record.summary) Battery: \(record.batterySummary).",
                 source: "gaugectl status (\(trigger))")

        // Verification after a restart: did the values written before the restart persist?
        if let pending = persisted.pending, pending.confirmed,
           let boot = bootTime, boot > pending.requestedAt {
            var changed: [String] = []
            for expected in pending.expected {
                let current = report.keys.first { $0.key == expected.key }?.current
                if current != expected.current { changed.append(expected.key.rawValue) }
            }
            let verification = VerificationResult(date: report.checkedAt, kind: pending.kind, build: build,
                                                  valuesPersisted: changed.isEmpty,
                                                  persistedCount: pending.expected.count - changed.count,
                                                  changedKeys: changed,
                                                  batteryPercent: battery.percent, powerState: battery.state)
            persisted.lastVerification = verification
            persisted.pending = nil
            let fileText = changed.isEmpty
                ? "All five values persisted."
                : "\(verification.persistedCount) of 5 persisted; rewritten: \(changed.joined(separator: ", "))."
            addEvent(.verification, "\(fileText) Battery: \(record.batterySummary).", source: "gaugectl status after restart")
        }
        save()
    }

    /// A recent report can be reused for the preview. The helper re-checks the checksum before writing.
    func reportForPreview() async -> CheckReport? {
        if let last = lastCheck, let report = last.report,
           Date().timeIntervalSince(last.date) < 300,
           (bootTime.map { last.date > $0 } ?? true) {
            return report
        }
        return await checkNow(trigger: "Preview before reapplying")
    }

    func applyWorkaround(previewed report: CheckReport, restart: Bool) async {
        var arguments = ["apply", "--expect-sha", report.sha256]
        if restart { arguments.append("--restart") }

        // Saved first: an immediate restart can end this app before the helper's answer arrives.
        persisted.pending = PendingVerification(
            kind: "apply", requestedAt: Date(), restartRequested: restart,
            expected: GaugingKey.allCases.map { KeyStatus(key: $0, current: GaugingSchema.expected($0)) },
            confirmed: false)
        save()

        let result = await runHelper(arguments,
                                     prompt: "Vedimac needs administrator access to back up and update the battery-gauging settings.",
                                     status: restart ? "Applying, then restarting…" : "Applying the workaround…")
        finishOperation(result, kind: .apply)
    }

    func restore(_ backup: BackupEntry, restart: Bool) async {
        var arguments = ["restore", "--backup-id", backup.id]
        if restart { arguments.append("--restart") }

        persisted.pending = PendingVerification(kind: "restore", requestedAt: Date(), restartRequested: restart,
                                                expected: backup.keys, confirmed: false)
        save()

        let result = await runHelper(arguments,
                                     prompt: "Vedimac needs administrator access to restore the selected backup.",
                                     status: restart ? "Restoring, then restarting…" : "Restoring the backup…")
        finishOperation(result, kind: .restore)
    }

    private func finishOperation(_ result: Result<HelperResponse, Error>, kind: EventKind) {
        let battery = reading
        switch result {
        case .failure(let error):
            persisted.pending = nil
            save()
            if !isCancellation(error) {
                alert = AlertMessage(title: "Nothing was changed", message: error.localizedDescription)
            }
        case .success(let response):
            guard response.ok, let operation = response.operation else {
                persisted.pending = nil
                save()
                alert = AlertMessage(title: "The operation stopped",
                                     message: response.errorMessage ?? "The helper reported a failure.")
                reloadBackups()
                return
            }
            if operation.wroteFile {
                persisted.pending?.confirmed = true
                persisted.pending?.expected = operation.after.keys
                let keys = operation.changedKeys.map { $0.rawValue }.joined(separator: ", ")
                let changedText = keys.isEmpty ? "no managed values" : keys
                let backupText = operation.backup?.id ?? "none"
                let levelText = battery.percent.map { "\($0)%" } ?? "unknown level"
                addEvent(kind, "Changed: \(changedText). Backup: \(backupText). Battery: \(battery.state.title) at \(levelText).",
                         source: "gaugectl \(operation.kind)")
                if !operation.restartRequested {
                    alert = AlertMessage(
                        title: kind == .apply ? "Workaround applied" : "Backup restored",
                        message: "The file was written and verified. powerd may overwrite it until the Mac restarts. After the next restart, Vedimac will offer to verify whether the values persisted.")
                }
            } else {
                persisted.pending = nil
                alert = AlertMessage(title: "Nothing to write",
                                     message: kind == .apply
                                        ? "All five values already match. The file was not written."
                                        : "The live file is already identical to this backup. The file was not written.")
            }
            recordCheck(operation.after, trigger: "After \(operation.kind)", battery: battery)
            reloadBackups()
        }
    }

    func importOriginal(from url: URL) async {
        let result = await runHelper(["import-original", "--file", url.path],
                                     prompt: "Vedimac needs administrator access to copy the original backup into its protected backup folder.",
                                     status: "Importing the original backup…")
        switch result {
        case .failure(let error):
            if !isCancellation(error) {
                alert = AlertMessage(title: "Import failed", message: error.localizedDescription)
            }
        case .success(let response):
            if response.ok {
                reloadBackups()
            } else {
                alert = AlertMessage(title: "This file cannot be used",
                                     message: response.errorMessage ?? "The file did not pass validation.")
            }
        }
    }

    func refreshPowerd(window: String? = nil) async {
        let chosen = window ?? powerd.window
        powerd.status = "Reading the unified log…"
        let snapshot = await Task.detached(priority: .utility) {
            PowerdLog.fetch(window: chosen)
        }.value
        powerd = snapshot
    }
}

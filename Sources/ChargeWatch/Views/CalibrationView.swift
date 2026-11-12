import SwiftUI
import AppKit
import GaugeCore

struct ApplyPreview: Identifiable {
    let id = UUID()
    let report: CheckReport
}

struct CalibrationView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let prompt = model.persisted.checkPrompt {
            PromptBanner(prompt: prompt)
        }
        statusCard
        valuesCard
        if model.persisted.lastVerification != nil || model.persisted.pending != nil {
            VerificationCard()
        }
        backupsCard
        PowerdCard()
        AboutWorkaroundCard()
    }

    // MARK: Status

    private var statusCard: some View {
        Card(title: "Calibration status", symbol: "gauge.with.dots.needle.50percent") {
            HStack(alignment: .top, spacing: 12) {
                ObservationTile(title: "File",
                                headline: model.lastCheck?.outcome.title ?? "Not checked yet",
                                detail: model.lastCheck?.summary ?? "Reading the five values needs administrator access.",
                                symbol: model.lastCheck?.outcome.symbol ?? "circle.dashed",
                                color: model.lastCheck?.outcome.color ?? .gray)
                ObservationTile(title: "Battery right now",
                                headline: model.reading.state.title,
                                detail: batteryDetail,
                                symbol: model.reading.state.symbol,
                                color: model.reading.state.color)
            }
            Text("These are separate observations. A rewritten value does not by itself mean the battery is charging, and charging does not by itself mean a value was rewritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let check = model.lastCheck {
                Text("Last check: \(Fmt.dateTimeSeconds(check.date)) on build \(check.build) (\(check.trigger)). Battery at that moment: \(check.batterySummary.lowercased()).")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let success = model.lastSuccessfulCheck {
                Text("Last successful read: \(Fmt.dateTimeSeconds(success.date)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button(model.persisted.checkPrompt?.buttonTitle ?? "Check now") {
                    Task { await model.checkNow(trigger: model.persisted.checkPrompt?.buttonTitle ?? "Check now") }
                }
                Button("Reapply calibration workaround") {
                    Task {
                        if let report = await model.reportForPreview() {
                            model.applyPreview = ApplyPreview(report: report)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                if let busy = model.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
            }
            .disabled(model.busy != nil)
        }
        .sheet(item: $model.applyPreview) { preview in
            ApplySheet(report: preview.report)
                .environmentObject(model)
        }
    }

    private var batteryDetail: String {
        var parts: [String] = []
        if let percent = model.reading.percent { parts.append("\(percent)%") }
        parts.append(model.reading.acConnected == true ? "adapter connected" : "adapter not connected")
        parts.append(model.gaugingStateReported ? "gauging state reported by macOS" : "no gauging state reported")
        return parts.joined(separator: ", ") + "."
    }

    // MARK: Values

    private var valuesCard: some View {
        Card(title: "The five values", symbol: "tablecells") {
            ValuesTable(keys: model.lastCheck?.report?.keys)
            if let report = model.lastCheck?.report {
                Text("File format: \(report.formatName) · owner \(report.metadata.uid):\(report.metadata.gid) · mode \(report.metadata.modeString) · pack \(report.packIdHash) (hashed)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if let message = model.lastCheck?.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(GaugingSchema.systemPlistPath)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    // MARK: Backups

    private var backupsCard: some View {
        Card(title: "Backups", symbol: "externaldrive.badge.timemachine") {
            if model.backups.isEmpty {
                Text("No backups yet. One is made and verified automatically before every write.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.backups) { backup in
                        BackupRow(backup: backup, currentBuild: model.build) {
                            model.restoreCandidate = backup
                        }
                        Divider()
                    }
                }
            }
            HStack {
                Button("Import original backup…") { importOriginal() }
                if model.originalBackup == nil {
                    Text("Import the backup your Terminal script made on November 6 to keep the pre-workaround state here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(model.busy != nil)
        }
        .sheet(item: $model.restoreCandidate) { backup in
            RestoreSheet(backup: backup)
                .environmentObject(model)
        }
    }

    private func importOriginal() {
        let panel = NSOpenPanel()
        panel.message = "Choose the original backup of com.apple.powerd.batterygauging.plist"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importOriginal(from: url) }
    }
}

// MARK: - Pieces

struct ObservationTile: View {
    let title: String
    let headline: String
    let detail: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Label(headline, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.10)))
    }
}

/// Current and expected value for each of the five keys.
/// With `keys == nil` (not read yet) only the expected values are shown.
struct ValuesTable: View {
    let keys: [KeyStatus]?
    var currentTitle = "Current"

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                Text("Key")
                Text("Location")
                Text(currentTitle)
                Text("Expected")
                Text("")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()
            ForEach(GaugingKey.allCases, id: \.rawValue) { key in
                let status = keys?.first { $0.key == key }
                GridRow {
                    Text(key.rawValue)
                        .font(.callout.monospaced())
                    Text(key.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(status?.current.display ?? "—")
                        .font(.callout.monospaced())
                        .foregroundStyle(status == nil ? Color.secondary : (status?.matches == true ? Color.primary : Color.orange))
                    Text(GaugingSchema.expected(key).display)
                        .font(.callout.monospaced())
                    matchLabel(status)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func matchLabel(_ status: KeyStatus?) -> some View {
        if let status {
            if status.matches {
                Label("Match", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("Differs", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        } else {
            Text("Not read")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct VerificationCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Verification after restart", symbol: "checkmark.seal") {
            if let pending = model.persisted.pending {
                Label("Waiting: the \(pending.kind == "apply" ? "workaround was applied" : "backup was restored") \(Fmt.dateTime(pending.requestedAt)). After the next restart, run the check to see whether the values persisted.",
                      systemImage: "hourglass")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = model.persisted.lastVerification {
                HStack(alignment: .top, spacing: 12) {
                    ObservationTile(title: "Values after restart",
                                    headline: result.valuesPersisted ? "All five persisted" : "\(result.persistedCount) of 5 persisted",
                                    detail: result.valuesPersisted
                                        ? "Every value written before the restart was still in place."
                                        : "Rewritten: \(result.changedKeys.joined(separator: ", ")).",
                                    symbol: result.valuesPersisted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                                    color: result.valuesPersisted ? .green : .orange)
                    ObservationTile(title: "Battery at that check",
                                    headline: result.powerState.title,
                                    detail: result.batteryPercent.map { "At \($0)%." } ?? "Level not available.",
                                    symbol: result.powerState.symbol,
                                    color: result.powerState.color)
                }
                Text("Verified \(Fmt.dateTimeSeconds(result.date)) on build \(result.build), after \(result.kind == "apply" ? "applying the workaround" : "restoring a backup").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct BackupRow: View {
    let backup: BackupEntry
    let currentBuild: String
    let restore: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: backup.kind == .importedOriginal ? "star.circle.fill" : "doc.badge.clock")
                .font(.title3)
                .foregroundStyle(backup.kind == .importedOriginal ? Color.yellow : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(kindTitle)
                        .fontWeight(.medium)
                    if backup.macOSBuild != currentBuild {
                        Text("build \(backup.macOSBuild)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .foregroundStyle(.orange)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                            .help("Created on a different macOS build than the current one (\(currentBuild)).")
                    }
                }
                Text("\(Fmt.dateTimeSeconds(backup.createdAt)) · \(matching) of 5 at expected values · sha256 \(String(backup.sha256.prefix(12)))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("Restore…", action: restore)
        }
        .padding(.vertical, 8)
    }

    private var matching: Int { backup.keys.filter { $0.matches }.count }

    private var kindTitle: String {
        switch backup.kind {
        case .importedOriginal: return "Original (pre-workaround) backup"
        case .preApply: return "Before applying the workaround"
        case .preRestore: return "Before restoring a backup"
        }
    }
}

struct PowerdCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "powerd messages", symbol: "text.alignleft") {
            Text("Battery-gauging messages from powerd in the unified log. Treat them as diagnostics: the gauging manager starting, or a note about PowerD-BatteryGaugingMitigation missing from an override array, is not evidence of a gauging charge. That needs an actual charging event.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(model.powerd.status)
                    .font(.callout)
                Spacer()
                Button("Since boot") { Task { await model.refreshPowerd(window: "boot") } }
                Button("Last 24 h") { Task { await model.refreshPowerd(window: "24h") } }
            }
            if !model.powerd.lines.isEmpty {
                ScrollView {
                    Text(model.powerd.lines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            Text("Source: log show, process powerd, messages mentioning “gauging”.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

struct AboutWorkaroundCard: View {
    var body: some View {
        Card(title: "What this workaround does", symbol: "info.circle") {
            Text("It sets four stored dates to 1 January 2030 (UTC) and clears the stored full-charge request, so that date-based requests for a full charge are deferred. The dates do not schedule the next calibration.")
                .fixedSize(horizontal: false, vertical: true)
            Text("It is unsupported and experimental. It may affect the accuracy of battery percentage or capacity estimates, and macOS can still decide to charge to 100% for other reasons. Its effect on your Mac is not yet proven.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}

// MARK: - Sheets

/// Preview of exactly what would change. Nothing is written until a button here is pressed.
struct ApplySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let report: CheckReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Reapply calibration workaround", systemImage: "wrench.and.screwdriver")
                .font(.title2.weight(.semibold))

            if report.differing.isEmpty {
                Label("All five values already match. Nothing will be written.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                ValuesTable(keys: report.keys)
            } else {
                Text("\(report.differing.count) of 5 values would change. The others stay as they are.")
                    .font(.headline)
                ForEach(report.differing) { key in
                    ChangeRow(key: key)
                }
                Text("Before writing, the current file is backed up and the copy is verified. If the file has changed since this preview (read \(Fmt.dateTimeSeconds(report.checkedAt))), nothing is written and you are asked to check again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BatteryNowLine()

            if !report.differing.isEmpty {
                Label("Apply and Restart restarts the Mac immediately, without asking open apps to save. Save your work first. Restarting helps prevent powerd from overwriting the file.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(report.differing.isEmpty ? "Done" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !report.differing.isEmpty {
                    Button("Apply") { run(restart: false) }
                    Button("Apply and Restart") { run(restart: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private func run(restart: Bool) {
        dismiss()
        Task { await model.applyWorkaround(previewed: report, restart: restart) }
    }
}

struct ChangeRow: View {
    let key: KeyStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.key.rawValue)
                    .font(.callout.monospaced().weight(.semibold))
                Text(key.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(key.current.display)
                    .foregroundStyle(.orange)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Text(key.expected.display)
                    .foregroundStyle(.green)
                Text("(\(key.expected.typeName))")
                    .foregroundStyle(.tertiary)
            }
            .font(.callout.monospaced())
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct BatteryNowLine: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.reading.state.symbol)
                .foregroundStyle(model.reading.state.color)
            Text("Battery right now: \(model.reading.state.title.lowercased())"
                 + (model.reading.percent.map { " at \($0)%" } ?? "") + ".")
        }
        .font(.callout)
    }
}

struct RestoreSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let backup: BackupEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Restore backup", systemImage: "arrow.uturn.backward.circle")
                .font(.title2.weight(.semibold))

            Text("This replaces the live file with the backup below, byte for byte. The current file is saved as a new backup first, and the selected backup is verified against its checksum.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(backup.id).font(.callout.monospaced())
                Text("Created \(Fmt.dateTimeSeconds(backup.createdAt)) on build \(backup.macOSBuild) · \(backup.formatName) · sha256 \(backup.sha256)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            ValuesTable(keys: backup.keys, currentTitle: "In this backup")

            if backup.macOSBuild != model.build {
                Label("This backup was created on build \(backup.macOSBuild). You are now on \(model.build). The file's schema is checked before anything is written, and the restore stops if it is not compatible.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            BatteryNowLine()

            Label("Restore and Restart restarts the Mac immediately, without asking open apps to save. Save your work first.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore") { run(restart: false) }
                Button("Restore and Restart") { run(restart: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 680)
    }

    private func run(restart: Bool) {
        dismiss()
        Task { await model.restore(backup, restart: restart) }
    }
}

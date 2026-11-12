import AppKit
import Foundation
import GaugeCore

/// Builds the exported files. Nothing is sent anywhere: the user chooses where each file is saved.
@MainActor
enum Exporter {

    static func historyCSV(_ model: AppModel) -> String {
        var lines = ["timestamp_utc,percent,ac_connected,charging,state"]
        for sample in model.samples {
            lines.append([GaugeFormat.iso(sample.t), String(sample.pct),
                          sample.ac ? "true" : "false", sample.chg ? "true" : "false",
                          sample.state.rawValue].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func eventsCSV(_ model: AppModel, redact: Bool) -> String {
        var lines = ["timestamp_utc,kind,detail,source"]
        for event in model.events {
            let detail = redact ? Redactor.redact(event.detail) : event.detail
            lines.append([GaugeFormat.iso(event.date), event.kind.rawValue, quote(detail), quote(event.source)]
                .joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func diagnosticReport(_ model: AppModel, redact: Bool) -> String {
        let r = model.reading
        var out: [String] = []

        func value(_ text: String?) -> String { text ?? "not available" }
        func row(_ label: String, _ text: String?, _ source: String) {
            out.append("- \(label): \(value(text)) _(\(source))_")
        }

        out.append("# Vedimac diagnostic report")
        out.append("")
        out.append("Generated: \(GaugeFormat.iso(Date()))")
        out.append(redact
            ? "Redaction: on. Personal paths, user name and serial-like identifiers are removed. The battery serial is never read; the battery pack identifier appears only as a short hash."
            : "Redaction: off.")
        out.append("")

        out.append("## System")
        out.append("- macOS \(model.osVersion), build \(model.build)")
        out.append("- Model identifier: \(SystemInfo.model)")
        out.append("- Last boot: \(model.bootTime.map { GaugeFormat.iso($0) } ?? "not available")")
        out.append("")

        out.append("## Battery right now")
        row("State", r.state.title, "IOPowerSources")
        row("Level", r.percent.map { "\($0) %" }, "IOPowerSources")
        row("AC connected", r.acConnected.map { $0 ? "yes" : "no" }, "IOPowerSources")
        row("Charging", r.isCharging.map { $0 ? "yes" : "no" }, "IOPowerSources")
        row("Condition", r.condition, "System Information")
        row("Maximum capacity (Apple)", r.appleMaximumCapacityPercent.map { "\($0) %" }, "System Information")
        row("Cycle count", r.cycleCount.map { String($0) }, "registry, undocumented key")
        row("Full-charge capacity", r.fullChargeCapacityMAh.map { "\($0) mAh" }, "registry, undocumented key")
        row("Design capacity", r.designCapacityMAh.map { "\($0) mAh" }, "registry, undocumented key")
        row("Health", r.healthPercent.map { Fmt.number($0, digits: 1) + " %" }, "calculated")
        row("Temperature", r.temperatureC.map { Fmt.number($0, digits: 1) + " °C" }, "registry, undocumented key")
        row("Voltage", r.voltageMV.map { Fmt.number(Double($0) / 1000, digits: 2) + " V" }, "registry, undocumented key")
        row("Current", r.currentMA.map { "\($0) mA" }, "registry, undocumented key")
        row("Power", r.powerW.map { Fmt.number($0, digits: 1) + " W" }, "calculated")
        let adapterName = r.adapterName.map { ", " + $0 } ?? ""
        row("Adapter", r.adapterWatts.map { "\($0) W" + adapterName }, "IOPowerSources adapter details")
        row("Not-charging reason code", r.notChargingReason.map { String($0) }, "registry, undocumented key")
        out.append("- Reference charge limit: \(model.persisted.limitPercent) % (entered by the user, not read from macOS)")
        if r.gaugingHints.isEmpty {
            out.append("- Gauging entries in the registry: none")
        } else {
            out.append("- Gauging entries in the registry:")
            for hint in r.gaugingHints { out.append("  - `\(hint)`") }
        }
        out.append("")

        out.append("## Calibration values")
        out.append("File: `\(GaugingSchema.systemPlistPath)`")
        out.append("")
        if let check = model.lastCheck {
            out.append("Last check: \(GaugeFormat.iso(check.date)) on build \(check.build) (\(check.trigger))")
            out.append("- File observation: **\(check.outcome.title)**. \(check.summary)")
            out.append("- Battery observation at that moment: \(check.batterySummary)")
            if let report = check.report {
                out.append("- Format: \(report.formatName); owner \(report.metadata.uid):\(report.metadata.gid); mode \(report.metadata.modeString); pack hash \(report.packIdHash)")
                out.append("")
                out.append("| Key | Location | Current | Expected | Match |")
                out.append("|---|---|---|---|---|")
                for key in report.keys {
                    out.append("| \(key.key.rawValue) | \(key.location) | \(key.current.display) | \(key.expected.display) | \(key.matches ? "yes" : "no") |")
                }
            }
        } else {
            out.append("The file has not been checked yet.")
        }
        if let success = model.lastSuccessfulCheck {
            out.append("")
            out.append("Last successful read: \(GaugeFormat.iso(success.date))")
        }
        if let verification = model.persisted.lastVerification {
            out.append("")
            out.append("Verification after restart (\(GaugeFormat.iso(verification.date)), \(verification.kind), build \(verification.build)):")
            let rewritten = verification.changedKeys.joined(separator: ", ")
            let fileText = verification.valuesPersisted
                ? "all five values persisted"
                : "\(verification.persistedCount) of 5 persisted; rewritten: \(rewritten)"
            let levelText = verification.batteryPercent.map { " at \($0) %" } ?? ""
            out.append("- File: " + fileText)
            out.append("- Battery: " + verification.powerState.title + levelText)
        }
        out.append("")

        out.append("## Check history")
        for check in model.persisted.checks.suffix(30) {
            out.append("- \(GaugeFormat.iso(check.date)) | build \(check.build) | \(check.outcome.title) | \(check.summary) | battery: \(check.batterySummary)")
        }
        if model.persisted.checks.isEmpty { out.append("- none") }
        out.append("")

        out.append("## Backups")
        for backup in model.backups {
            out.append("- \(backup.id) | \(backup.kind.rawValue) | \(GaugeFormat.iso(backup.createdAt)) | build \(backup.macOSBuild) | sha256 \(backup.sha256)")
        }
        if model.backups.isEmpty { out.append("- none") }
        out.append("")

        out.append("## Diagnostic events")
        for event in model.events.suffix(200) {
            out.append("- \(GaugeFormat.iso(event.date)) | \(event.kind.title) | \(event.detail) | source: \(event.source)")
        }
        if model.events.isEmpty { out.append("- none") }
        out.append("")

        out.append("## powerd messages")
        out.append("These are diagnostic log messages. On their own they do not show that a gauging charge took place.")
        out.append("")
        out.append(model.powerd.status)
        if !model.powerd.lines.isEmpty {
            out.append("")
            out.append("```")
            out.append(contentsOf: model.powerd.lines)
            out.append("```")
        }
        out.append("")

        out.append("## pmset -g batt")
        out.append("```")
        out.append(model.pmsetText.trimmingCharacters(in: .whitespacesAndNewlines))
        out.append("```")
        out.append("")

        let text = out.joined(separator: "\n")
        return redact ? Redactor.redact(text) : text
    }

    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func stamp() -> String {
        GaugeFormat.fileStamp(Date())
    }
}

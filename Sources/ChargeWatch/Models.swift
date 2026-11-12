import Foundation
import SwiftUI
import GaugeCore

/// What the battery is doing. "Plugged in" and "charging" are deliberately separate facts.
enum PowerState: String, Codable {
    case charging
    case pluggedNotCharging
    case discharging
    case unknown

    var title: String {
        switch self {
        case .charging: return "Charging"
        case .pluggedNotCharging: return "Plugged in, not charging"
        case .discharging: return "On battery"
        case .unknown: return "Unknown"
        }
    }

    var shortTitle: String {
        switch self {
        case .charging: return "Charging"
        case .pluggedNotCharging: return "Not charging"
        case .discharging: return "On battery"
        case .unknown: return "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .charging: return "bolt.fill"
        case .pluggedNotCharging: return "powerplug.fill"
        case .discharging: return "battery.75percent"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .charging: return .green
        case .pluggedNotCharging: return .blue
        case .discharging: return .orange
        case .unknown: return .gray
        }
    }
}

/// One live reading. Every field is optional: a missing value is shown as "Not available".
struct BatteryReading {
    var timestamp: Date
    var hasBattery = false

    // IOPowerSources (public API)
    var percent: Int?
    var acConnected: Bool?
    var isCharging: Bool?
    var isCharged: Bool?
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var condition: String?
    /// Apple's own "Maximum Capacity" percentage, from System Information.
    var appleMaximumCapacityPercent: Int?

    // Power adapter (public API: IOPSCopyExternalPowerAdapterDetails)
    var adapterWatts: Int?
    var adapterName: String?
    var adapterVoltageMV: Int?
    var adapterCurrentMA: Int?

    // AppleSmartBattery registry entry (undocumented keys, may change between macOS versions)
    var cycleCount: Int?
    var designCapacityMAh: Int?
    var fullChargeCapacityMAh: Int?
    var temperatureC: Double?
    var voltageMV: Int?
    var currentMA: Int?
    var notChargingReason: Int?
    /// Registry keys or values that mention gauging, as "path = value".
    var gaugingHints: [String] = []
    /// True when a registry string value mentions gauging.
    var gaugingStateInRegistry = false

    var state: PowerState {
        guard hasBattery, let ac = acConnected else { return .unknown }
        if !ac { return .discharging }
        return (isCharging ?? false) ? .charging : .pluggedNotCharging
    }

    /// Derived: voltage x current. Negative while discharging.
    var powerW: Double? {
        guard let v = voltageMV, let a = currentMA else { return nil }
        return Double(v) * Double(a) / 1_000_000
    }

    /// Derived: full-charge capacity / design capacity.
    var healthPercent: Double? {
        guard let full = fullChargeCapacityMAh, let design = designCapacityMAh, design > 0 else { return nil }
        return Double(full) / Double(design) * 100
    }

    var timeEstimate: String? {
        switch state {
        case .charging:
            if let m = minutesToFull, m > 0 { return "\(Fmt.duration(minutes: m)) until charged" }
        case .discharging:
            if let m = minutesToEmpty, m > 0 { return "\(Fmt.duration(minutes: m)) remaining" }
        default:
            break
        }
        return nil
    }
}

struct Sample: Codable, Identifiable {
    var t: Date
    var pct: Int
    var ac: Bool
    var chg: Bool

    var id: Date { t }
    var state: PowerState { !ac ? .discharging : (chg ? .charging : .pluggedNotCharging) }
}

enum EventKind: String, Codable {
    case buildChange
    case restart
    case calibrationConfirmed
    case chargeAboveLimit
    case gaugingHint
    case check
    case apply
    case restore
    case verification

    var title: String {
        switch self {
        case .buildChange: return "macOS build change"
        case .restart: return "Restart"
        case .calibrationConfirmed: return "Confirmed gauging charge"
        case .chargeAboveLimit: return "Charging above limit"
        case .gaugingHint: return "Gauging state reported"
        case .check: return "Calibration check"
        case .apply: return "Workaround applied"
        case .restore: return "Backup restored"
        case .verification: return "Verification after restart"
        }
    }

    var symbol: String {
        switch self {
        case .buildChange: return "arrow.down.circle.fill"
        case .restart: return "power.circle.fill"
        case .calibrationConfirmed: return "exclamationmark.triangle.fill"
        case .chargeAboveLimit: return "arrow.up.right.circle.fill"
        case .gaugingHint: return "gauge.with.dots.needle.33percent"
        case .check: return "checklist"
        case .apply: return "wrench.and.screwdriver.fill"
        case .restore: return "arrow.uturn.backward.circle.fill"
        case .verification: return "checkmark.seal.fill"
        }
    }

    var color: Color {
        switch self {
        case .buildChange: return .purple
        case .restart: return .gray
        case .calibrationConfirmed: return .red
        case .chargeAboveLimit: return .orange
        case .gaugingHint: return .yellow
        case .check: return .blue
        case .apply: return .teal
        case .restore: return .indigo
        case .verification: return .green
        }
    }

    /// Shown as markers on the history chart.
    var isChartMarker: Bool {
        switch self {
        case .buildChange, .restart, .calibrationConfirmed, .chargeAboveLimit, .apply, .restore: return true
        default: return false
        }
    }
}

struct DiagnosticEvent: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var kind: EventKind
    var detail: String
    /// Where the observation came from (API, command or file).
    var source: String
}

enum CheckOutcome: String, Codable {
    case fullMatch
    case partialRewrite
    case fullMismatch
    case unreadable

    init(_ state: MatchState) {
        switch state {
        case .fullMatch: self = .fullMatch
        case .partialRewrite: self = .partialRewrite
        case .fullMismatch: self = .fullMismatch
        }
    }

    var title: String {
        switch self {
        case .fullMatch: return "Full match"
        case .partialRewrite: return "Partial rewrite"
        case .fullMismatch: return "Full mismatch"
        case .unreadable: return "Unreadable or unsupported"
        }
    }

    var symbol: String {
        switch self {
        case .fullMatch: return "checkmark.circle.fill"
        case .partialRewrite: return "exclamationmark.circle.fill"
        case .fullMismatch: return "xmark.circle.fill"
        case .unreadable: return "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .fullMatch: return .green
        case .partialRewrite: return .orange
        case .fullMismatch: return .red
        case .unreadable: return .gray
        }
    }
}

/// One check of the file, stored together with what the battery was doing at that moment.
/// The two are separate observations and are always shown side by side.
struct CheckRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var build: String
    var trigger: String
    var outcome: CheckOutcome
    var report: CheckReport?
    var errorMessage: String?
    var batteryPercent: Int?
    var powerState: PowerState

    var summary: String {
        switch outcome {
        case .fullMatch:
            return "All five values match."
        case .partialRewrite, .fullMismatch:
            let differing = report?.differing.map { $0.key.rawValue } ?? []
            return "\(differing.count) of 5 differ: \(differing.joined(separator: ", "))."
        case .unreadable:
            return errorMessage ?? "The file could not be read."
        }
    }

    var batterySummary: String {
        if let p = batteryPercent { return "\(powerState.title) at \(p)%" }
        return powerState.title
    }
}

struct CheckPrompt: Codable {
    enum Reason: String, Codable {
        case buildChange
        case restart
        case verify
    }
    var reason: Reason
    var detail: String
    var date: Date

    var buttonTitle: String {
        switch reason {
        case .buildChange: return "Check after update"
        case .restart: return "Check after restart"
        case .verify: return "Verify after restart"
        }
    }
}

/// Saved before an apply or restore so the result can be verified after the next boot.
struct PendingVerification: Codable {
    /// "apply" or "restore"
    var kind: String
    var requestedAt: Date
    var restartRequested: Bool
    /// The values the file should have after the operation.
    var expected: [KeyStatus]
    /// True once the helper has reported that it wrote the file.
    var confirmed: Bool
}

struct VerificationResult: Codable {
    var date: Date
    var kind: String
    var build: String
    var valuesPersisted: Bool
    var persistedCount: Int
    var changedKeys: [String]
    var batteryPercent: Int?
    var powerState: PowerState
}

struct PersistedState: Codable {
    var lastSeenBuild: String?
    var lastSeenBoot: Date?
    /// The user's own reference setting. macOS does not expose the Charge Limit through a public interface.
    var limitPercent: Int = 80
    var checks: [CheckRecord] = []
    var checkPrompt: CheckPrompt?
    var pending: PendingVerification?
    var lastVerification: VerificationResult?
}

struct AlertMessage: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

enum Fmt {
    static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func dateTimeSeconds(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}

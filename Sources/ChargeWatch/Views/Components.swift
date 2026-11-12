import SwiftUI

/// Where a reading comes from. Shown next to every value.
enum SourceKind {
    case publicAPI
    case systemReport
    case registry
    case derived
    case reference

    var label: String {
        switch self {
        case .publicAPI: return "Public API"
        case .systemReport: return "System report"
        case .registry: return "Private key"
        case .derived: return "Calculated"
        case .reference: return "Your setting"
        }
    }

    var help: String {
        switch self {
        case .publicAPI:
            return "Read through a documented macOS interface (IOPowerSources)."
        case .systemReport:
            return "Read from System Information (system_profiler SPPowerDataType), refreshed every ten minutes."
        case .registry:
            return "Read from the AppleSmartBattery registry entry. The key is undocumented and may change between macOS versions."
        case .derived:
            return "Calculated by Vedimac from other readings."
        case .reference:
            return "A value you entered. It is not read from macOS."
        }
    }

    var color: Color {
        switch self {
        case .publicAPI: return .green
        case .systemReport: return .teal
        case .registry: return .orange
        case .derived: return .purple
        case .reference: return .blue
        }
    }
}

struct SourceBadge: View {
    let kind: SourceKind

    var body: some View {
        Text(kind.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(kind.color)
            .background(Capsule().fill(kind.color.opacity(0.12)))
            .help(kind.help)
    }
}

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

/// One labelled reading with its unit and source. A missing value is stated, never left blank.
struct MetricRow: View {
    let label: String
    let value: String?
    let source: SourceKind
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .fontWeight(.medium)
                        .monospacedDigit()
                } else {
                    Text("Not available")
                        .foregroundStyle(.tertiary)
                }
                SourceBadge(kind: source)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A yes/no fact with an icon, a word and a colour, so it never depends on colour alone.
struct StatusTile: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(active ? color : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? color.opacity(0.12) : Color.primary.opacity(0.05))
        )
    }
}

/// The two facts people confuse: is power connected, and is the battery charging.
struct PowerFacts: View {
    let reading: BatteryReading

    var body: some View {
        HStack(spacing: 10) {
            StatusTile(title: "Power adapter",
                       value: adapterText,
                       symbol: "powerplug.fill",
                       color: .blue,
                       active: reading.acConnected == true)
            StatusTile(title: "Battery",
                       value: chargingText,
                       symbol: reading.isCharging == true ? "bolt.fill" : "bolt.slash.fill",
                       color: .green,
                       active: reading.isCharging == true)
        }
    }

    private var adapterText: String {
        switch reading.acConnected {
        case .some(true): return "Connected"
        case .some(false): return "Not connected"
        case .none: return "Unknown"
        }
    }

    private var chargingText: String {
        switch reading.isCharging {
        case .some(true): return "Charging"
        case .some(false): return "Not charging"
        case .none: return "Unknown"
        }
    }
}

struct PercentRing: View {
    let percent: Int?
    let limit: Int
    let color: Color
    var size: CGFloat = 150
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // Tick at the reference limit.
            Circle()
                .trim(from: max(0, CGFloat(limit) / 100 - 0.004), to: min(1, CGFloat(limit) / 100 + 0.004))
                .stroke(Color.primary.opacity(0.7), lineWidth: lineWidth + 6)
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                if let percent {
                    Text("\(percent)")
                        .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    + Text("%")
                        .font(.system(size: size * 0.15, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                } else {
                    Text("—")
                        .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                }
                Text("limit \(limit)%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .padding(lineWidth / 2 + 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(percent.map { "Battery \($0) percent, reference limit \(limit) percent" } ?? "Battery level unknown")
    }
}

struct PromptBanner: View {
    @EnvironmentObject var model: AppModel
    let prompt: CheckPrompt

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.buttonTitle)
                    .font(.headline)
                Text(prompt.detail + " Battery right now: " + model.reading.state.title.lowercased()
                     + (model.reading.percent.map { " at \($0)%." } ?? "."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(prompt.buttonTitle) {
                model.section = .calibration
                Task { await model.checkNow(trigger: prompt.buttonTitle) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy != nil)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}

/// The result of the last file check, as a coloured word with an icon.
struct OutcomeBadge: View {
    let outcome: CheckOutcome?

    var body: some View {
        Label(outcome?.title ?? "Not checked yet",
              systemImage: outcome?.symbol ?? "circle.dashed")
            .font(.callout.weight(.semibold))
            .foregroundStyle(outcome?.color ?? .secondary)
    }
}

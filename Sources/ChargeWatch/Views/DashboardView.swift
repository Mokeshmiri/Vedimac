import SwiftUI
import AppKit

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview
    case history
    case calibration
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .history: return "History"
        case .calibration: return "Calibration"
        case .export: return "Export & settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "battery.75percent"
        case .history: return "chart.xyaxis.line"
        case .calibration: return "gauge.with.dots.needle.50percent"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.allCases, selection: $model.section) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.section ?? .overview {
                    case .overview: OverviewView()
                    case .history: HistoryView()
                    case .calibration: CalibrationView()
                    case .export: ExportView()
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100, alignment: .leading)
            }
            .navigationTitle((model.section ?? .overview).title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if let busy = model.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(busy).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .alert(model.alert?.title ?? "",
               isPresented: Binding(get: { model.alert != nil },
                                    set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert?.message ?? "")
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let prompt = model.persisted.checkPrompt {
            PromptBanner(prompt: prompt)
        }
        HeroCard()
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
                HealthCard()
                LimitCard()
            }
            VStack(spacing: 16) {
                PowerCard()
                AdapterCard()
                CalibrationSummaryCard()
            }
        }
    }
}

struct HeroCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let reading = model.reading
        HStack(alignment: .center, spacing: 24) {
            PercentRing(percent: reading.percent, limit: model.persisted.limitPercent, color: reading.state.color)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(reading.state.title, systemImage: reading.state.symbol)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .foregroundStyle(reading.state.color)
                    Text(subtitle(reading))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                PowerFacts(reading: reading)
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text(reading.timeEstimate ?? "No time estimate from macOS right now")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [reading.state.color.opacity(0.16), Color(nsColor: .controlBackgroundColor)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    private func subtitle(_ reading: BatteryReading) -> String {
        let limit = model.persisted.limitPercent
        switch reading.state {
        case .charging:
            if let percent = reading.percent, percent >= limit + 3 {
                return model.gaugingStateReported
                    ? "The battery is taking charge above your \(limit)% limit, and macOS reports a gauging state."
                    : "The battery is taking charge above your \(limit)% limit. No gauging state is reported right now."
            }
            return "The adapter is connected and the battery is taking charge."
        case .pluggedNotCharging:
            return "The adapter is connected, but the battery is not taking charge. The Mac is running from the adapter."
        case .discharging:
            return "The adapter is not connected. The Mac is running from the battery."
        case .unknown:
            return "macOS did not report a battery state."
        }
    }
}

struct HealthCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let r = model.reading
        Card(title: "Battery health", symbol: "heart.text.square") {
            MetricRow(label: "Condition", value: r.condition, source: .systemReport)
            MetricRow(label: "Maximum capacity", value: r.appleMaximumCapacityPercent.map { "\($0) %" },
                      source: .systemReport,
                      note: "Apple's figure, as shown in System Settings › Battery.")
            MetricRow(label: "Raw health", value: r.healthPercent.map { Fmt.number($0, digits: 1) + " %" },
                      source: .derived,
                      note: "Full-charge ÷ design capacity from the raw readings. Apple calculates its figure differently.")
            MetricRow(label: "Cycle count", value: r.cycleCount.map { "\($0) cycles" }, source: .registry)
            MetricRow(label: "Full-charge capacity", value: r.fullChargeCapacityMAh.map { "\($0) mAh" }, source: .registry)
            MetricRow(label: "Design capacity", value: r.designCapacityMAh.map { "\($0) mAh" }, source: .registry)
            MetricRow(label: "Temperature", value: r.temperatureC.map { Fmt.number($0, digits: 1) + " °C" }, source: .registry,
                      note: r.temperatureC == nil ? "This Mac does not report battery temperature." : nil)
        }
    }
}

struct PowerCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let r = model.reading
        Card(title: "Power", symbol: "bolt.horizontal") {
            MetricRow(label: "Voltage", value: r.voltageMV.map { Fmt.number(Double($0) / 1000, digits: 2) + " V" }, source: .registry)
            MetricRow(label: "Current", value: r.currentMA.map { "\($0) mA" }, source: .registry,
                      note: "Negative while the battery is discharging.")
            MetricRow(label: "Battery power", value: r.powerW.map { Fmt.number($0, digits: 1) + " W" }, source: .derived,
                      note: "Voltage × current, into (+) or out of (−) the battery.")
            MetricRow(label: "Time estimate", value: r.timeEstimate, source: .publicAPI)
        }
    }
}

struct AdapterCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let r = model.reading
        Card(title: "Adapter", symbol: "powerplug") {
            MetricRow(label: "Connected", value: r.acConnected.map { $0 ? "Yes" : "No" }, source: .publicAPI)
            MetricRow(label: "Rated power", value: r.adapterWatts.map { "\($0) W" }, source: .publicAPI)
            MetricRow(label: "Name", value: r.adapterName, source: .publicAPI)
            MetricRow(label: "Voltage", value: r.adapterVoltageMV.map { Fmt.number(Double($0) / 1000, digits: 1) + " V" }, source: .publicAPI)
            MetricRow(label: "Current", value: r.adapterCurrentMA.map { Fmt.number(Double($0) / 1000, digits: 2) + " A" }, source: .publicAPI)
        }
    }
}

struct LimitCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Charge limit", symbol: "flag.checkered") {
            HStack {
                Text("Reference limit")
                    .foregroundStyle(.secondary)
                Spacer()
                Stepper(value: Binding(get: { model.persisted.limitPercent },
                                       set: { model.setLimit($0) }),
                        in: 50...100, step: 5) {
                    Text("\(model.persisted.limitPercent) %")
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .fixedSize()
                SourceBadge(kind: .reference)
            }
            Text("macOS does not offer a public way to read the Charge Limit setting, so this is your own reference value. Set it to match System Settings › Battery. Vedimac uses it for the chart line and to flag charging more than 3 points above it. Holding a few points either side of the limit is normal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CalibrationSummaryCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Calibration workaround", symbol: "gauge.with.dots.needle.50percent") {
            OutcomeBadge(outcome: model.lastCheck?.outcome)
            if let check = model.lastCheck {
                Text(check.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Checked \(Fmt.dateTime(check.date)) on build \(check.build). Battery then: \(check.batterySummary.lowercased()).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The five values have not been read yet. Reading them needs administrator access.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open calibration") { model.section = .calibration }
        }
    }
}

// MARK: - Export & settings

struct ExportView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Export", symbol: "square.and.arrow.up") {
            Toggle("Redact personal paths, user name and serial-like identifiers", isOn: $model.redactExports)
            Text("The battery serial is never read or stored, and the battery pack identifier only ever appears as a short hash. Keep redaction on for anything you share.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Export battery history (CSV)…") {
                    Exporter.save(Exporter.historyCSV(model), suggestedName: "chargewatch-history-\(Exporter.stamp()).csv")
                }
                Button("Export events (CSV)…") {
                    Exporter.save(Exporter.eventsCSV(model, redact: model.redactExports), suggestedName: "chargewatch-events-\(Exporter.stamp()).csv")
                }
                Button("Export diagnostic report…") {
                    Task {
                        await model.refreshPowerd()
                        Exporter.save(Exporter.diagnosticReport(model, redact: model.redactExports),
                                      suggestedName: "chargewatch-diagnostics-\(Exporter.stamp()).md")
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            Text("\(model.samples.count) samples and \(model.events.count) events recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Card(title: "Your data", symbol: "lock.shield") {
            Text("Everything stays on this Mac. Vedimac makes no network connections. History and settings are in your Library; plist backups are in a folder only administrators can read.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show history folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.dataDirectory])
                }
                Button("Show backup folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "/Library/Application Support/ChargeWatch")])
                }
                .disabled(model.backups.isEmpty)
            }
        }

        Card(title: "Settings", symbol: "gearshape") {
            Toggle("Open Vedimac at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { newValue in
                    model.launchAtLogin = LoginItem.set(newValue)
                }))
            Text("History is only recorded while Vedimac is running. Opening it at login also lets it notice restarts and macOS updates straight away.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MetricRow(label: "macOS", value: "\(model.osVersion) (\(model.build))", source: .publicAPI)
            MetricRow(label: "Last boot", value: model.bootTime.map { Fmt.dateTime($0) }, source: .publicAPI)
        }
    }
}

import SwiftUI
import Charts

enum HistoryRange: String, CaseIterable, Identifiable {
    case sixHours = "6 h"
    case day = "24 h"
    case week = "7 d"
    case month = "30 d"

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }
}

struct ChartPoint: Identifiable {
    let id: Int
    let date: Date
    let percent: Int
    /// Points recorded without a gap share a segment, so the line breaks while the app was not running.
    let segment: Int
}

struct StateBand: Identifiable {
    let id: Int
    let start: Date
    let end: Date
    let state: PowerState
}

struct HistorySeries {
    var points: [ChartPoint] = []
    var bands: [StateBand] = []

    /// A gap longer than this means nothing was recorded (app closed or Mac asleep).
    static let gap: TimeInterval = 10 * 60

    init(samples: [Sample], from start: Date) {
        let visible = samples.filter { $0.t >= start }
        guard !visible.isEmpty else { return }

        // Bands: time spent charging, or plugged in without charging.
        var bandID = 0
        var open: (start: Date, end: Date, state: PowerState)?
        func close(_ band: (start: Date, end: Date, state: PowerState)?, into bands: inout [StateBand], id: inout Int) {
            guard let band, band.end > band.start, band.state != .discharging else { return }
            bands.append(StateBand(id: id, start: band.start, end: band.end, state: band.state))
            id += 1
        }
        for index in visible.indices {
            let sample = visible[index]
            let next: Date? = index + 1 < visible.count ? visible[index + 1].t : nil
            let end: Date
            if let next, next.timeIntervalSince(sample.t) <= HistorySeries.gap {
                end = next
            } else {
                end = sample.t.addingTimeInterval(60)
            }
            if let current = open, current.state == sample.state, sample.t <= current.end {
                open = (current.start, end, current.state)
            } else {
                close(open, into: &bands, id: &bandID)
                open = (sample.t, end, sample.state)
            }
        }
        close(open, into: &bands, id: &bandID)

        // Line: thinned to at most ~700 points, broken at gaps.
        let step = max(1, visible.count / 700)
        var segment = 0
        var previous: Date?
        for index in visible.indices {
            let sample = visible[index]
            if let previous, sample.t.timeIntervalSince(previous) > HistorySeries.gap { segment += 1 }
            previous = sample.t
            let isLast = index == visible.count - 1
            if index % step == 0 || isLast {
                points.append(ChartPoint(id: index, date: sample.t, percent: sample.pct, segment: segment))
            }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let end = Date()
        let start = end.addingTimeInterval(-model.historyRange.seconds)
        let series = HistorySeries(samples: model.samples, from: start)
        let markers = model.events.filter { $0.kind.isChartMarker && $0.date >= start }

        Card(title: "Battery level", symbol: "chart.xyaxis.line") {
            HStack {
                Picker("Range", selection: $model.historyRange) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Spacer()
                ChartLegend()
            }
            if series.points.isEmpty {
                Text("No samples in this period yet. History is recorded about once a minute while Vedimac is running.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .center)
            } else {
                HistoryChart(series: series, markers: markers, limit: model.persisted.limitPercent,
                             start: start, end: end)
                    .frame(height: 300)
            }
            Text("Shaded areas show when power was connected: green while the battery was charging, blue while it was plugged in without charging. Gaps mean nothing was recorded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Card(title: "Diagnostic events", symbol: "list.bullet.rectangle") {
            if model.events.isEmpty {
                Text("No events recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                EventList(events: Array(model.events.suffix(100).reversed()))
            }
        }
    }
}

struct ChartLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(color: PowerState.charging.color, text: "Charging")
            item(color: PowerState.pluggedNotCharging.color, text: "Plugged in, not charging")
            HStack(spacing: 5) {
                Rectangle()
                    .fill(Color.secondary)
                    .frame(width: 14, height: 1.5)
                Text("Limit")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func item(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.35))
                .frame(width: 12, height: 12)
            Text(text)
        }
    }
}

struct HistoryChart: View {
    let series: HistorySeries
    let markers: [DiagnosticEvent]
    let limit: Int
    let start: Date
    let end: Date

    var body: some View {
        Chart {
            bandMarks
            lineMarks
            limitMark
            eventMarks
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 20, 40, 60, 80, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Int.self) {
                        Text("\(number)%")
                    }
                }
            }
        }
    }

    @ChartContentBuilder
    private var bandMarks: some ChartContent {
        ForEach(series.bands) { band in
            RectangleMark(xStart: .value("Start", band.start),
                          xEnd: .value("End", band.end),
                          yStart: .value("Low", 0),
                          yEnd: .value("High", 100))
                .foregroundStyle(band.state.color.opacity(0.16))
        }
    }

    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        ForEach(series.points) { point in
            LineMark(x: .value("Time", point.date),
                     y: .value("Battery", point.percent),
                     series: .value("Segment", point.segment))
                .foregroundStyle(Color.primary)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    @ChartContentBuilder
    private var limitMark: some ChartContent {
        RuleMark(y: .value("Limit", limit))
            .foregroundStyle(Color.secondary)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .annotation(position: .top, alignment: .trailing) {
                Text("Limit \(limit)%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
    }

    @ChartContentBuilder
    private var eventMarks: some ChartContent {
        ForEach(markers) { event in
            RuleMark(x: .value("Event", event.date))
                .foregroundStyle(event.kind.color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .annotation(position: .top, alignment: .center) {
                    Image(systemName: event.kind.symbol)
                        .font(.caption2)
                        .foregroundStyle(event.kind.color)
                        .help(event.kind.title + ": " + event.detail)
                }
        }
    }
}

struct EventList: View {
    let events: [DiagnosticEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: event.kind.symbol)
                        .foregroundStyle(event.kind.color)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(event.kind.title)
                                .fontWeight(.medium)
                            Spacer()
                            Text(Fmt.dateTimeSeconds(event.date))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(event.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text("Source: \(event.source)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 8)
                Divider()
            }
        }
    }
}

import SwiftUI
import AppKit
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the state after the change, which stays unchanged if macOS refuses.
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Vedimac: login item change failed: \(error.localizedDescription)")
        }
        return isEnabled
    }
}

/// The panel that opens from the menu-bar item.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let reading = model.reading
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                PercentRing(percent: reading.percent, limit: model.persisted.limitPercent,
                            color: reading.state.color, size: 76, lineWidth: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Label(reading.state.title, systemImage: reading.state.symbol)
                        .font(.headline)
                        .foregroundStyle(reading.state.color)
                    Text(reading.timeEstimate ?? "No time estimate right now")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let watts = reading.powerW {
                        Text(Fmt.number(watts, digits: 1) + " W battery power")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            PowerFacts(reading: reading)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Calibration values")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    OutcomeBadge(outcome: model.lastCheck?.outcome)
                        .font(.caption)
                }
                if let check = model.lastCheck {
                    Text("Checked \(Fmt.dateTime(check.date)), build \(check.build)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if let prompt = model.persisted.checkPrompt {
                    Label(prompt.buttonTitle + " recommended", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            HStack {
                Button("Open Dashboard") { openDashboard(.overview) }
                    .buttonStyle(.borderedProminent)
                Button(model.persisted.checkPrompt?.buttonTitle ?? "Check now") {
                    openDashboard(.calibration)
                    Task { await model.checkNow(trigger: model.persisted.checkPrompt?.buttonTitle ?? "Check now") }
                }
                .disabled(model.busy != nil)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func openDashboard(_ section: DashboardSection) {
        model.section = section
        openWindow(id: "dashboard")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

import SwiftUI

@main
struct VedimacApp: App {
    @StateObject private var model = AppModel()

    init() {
        DockPresence.apply()
    }

    var body: some Scene {
        Window("Vedimac", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1000, height: 740)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(reading: model.reading)
        }
        .menuBarExtraStyle(.window)
    }
}

/// A compact menu-bar label for the current power state.
struct MenuBarLabel: View {
    let reading: BatteryReading

    var body: some View {
        switch reading.state {
        case .discharging:
            if let percent = reading.percent {
                Text("\(percent)%")
                    .accessibilityLabel("On battery, \(percent) percent")
            } else {
                powerStateIcon
            }
        default:
            powerStateIcon
        }
    }

    private var powerStateIcon: some View {
        Image(systemName: reading.state.symbol)
            .accessibilityLabel(Text(reading.state.title))
    }
}

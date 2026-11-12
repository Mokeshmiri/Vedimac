import SwiftUI

@main
struct VedimacApp: App {
    @StateObject private var model = AppModel()

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

/// The menu-bar item: an icon that reflects the power state, plus the percentage.
struct MenuBarLabel: View {
    let reading: BatteryReading

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: reading.state.symbol)
            if let percent = reading.percent {
                Text("\(percent)%")
            }
        }
    }
}

import SwiftUI

@main
struct EnerGApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("EnerG", systemImage: "bolt.batteryblock") {
            PopoverView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

import Testing
@testable import EnerGCore

struct LabelTests {
    private func status(_ state: ChargeState, percent: Int = 80, effectiveLimit: Int? = 80,
                        adapterConnected: Bool = true, adapterWatts: Int? = 96) -> Status {
        Status(state: state, settings: Settings(),
               snapshot: BatterySnapshot(percent: percent, isCharging: state == .charging,
                                         adapterConnected: adapterConnected, adapterWatts: adapterWatts,
                                         batteryWatts: 0, systemWatts: 10),
               effectiveLimit: effectiveLimit, toppingUp: false, warnings: [])
    }

    // A Weak Adapter's note wins over "idle": the rating is what the user needs to know.
    @Test func adapterLabel() {
        #expect(status(.onBattery, adapterConnected: false).adapterLabel == "Unplugged")
        #expect(status(.atLimit, adapterWatts: nil).adapterLabel == "Connected")
        #expect(status(.atLimit, adapterWatts: 96).adapterLabel == "96 W")
        #expect(status(.limitDrain, percent: 85, adapterWatts: 96).adapterLabel == "96 W · idle")
        #expect(status(.atLimit, adapterWatts: 50).adapterLabel == "50 W")
        #expect(status(.atLimit, adapterWatts: 45).adapterLabel == "45 W · light work")
        #expect(status(.limitDrain, percent: 85, adapterWatts: 30).adapterLabel == "30 W · light work")
    }

    @Test func adapterLabelWithoutASnapshot() {
        let unreadable = Status(state: .unknown, settings: Settings(), snapshot: nil,
                                effectiveLimit: nil, toppingUp: false, warnings: [.batteryUnreadable])
        #expect(unreadable.adapterLabel == "—")
    }

    @Test func stateLabel() {
        #expect(status(.limitDrain, percent: 85, effectiveLimit: 60).stateLabel == "Draining to 60%")
        #expect(status(.limitDrain, percent: 85, effectiveLimit: nil).stateLabel == "Draining to limit")
        #expect(status(.atLimit, percent: 80).stateLabel == "Holding at 80%")
        #expect(status(.atLimit, percent: 77).stateLabel == "Not charging · resumes below 75%")
        #expect(status(.atLimit, percent: 74).stateLabel == "Not charging")
        #expect(status(.atLimit, effectiveLimit: nil).stateLabel == "Not charging")
        #expect(status(.charging, percent: 70).stateLabel == "Charging")
    }
}

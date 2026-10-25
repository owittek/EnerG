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

    @Test func adapterLabel() {
        #expect(status(.onBattery, adapterConnected: false).adapterLabel == "Unplugged")
        #expect(status(.atLimit, adapterWatts: nil).adapterLabel == "Connected")
        #expect(status(.atLimit, adapterWatts: 96).adapterLabel == "96 W")
        #expect(status(.atLimit, adapterWatts: 30).adapterLabel == "30 W")
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

    @Test func warningLabel() {
        #expect(Warning.lowLimitUnsupported.label == "This Mac doesn't accept limits below 80%. Holding at 80%.")
        #expect(Warning.calibrating.label == "Charge Limit paused by macOS")
        #expect(Warning.unavailable(.chargeLimit).label == "Charge Limit is unavailable on this Mac.")
        #expect(Warning.unavailable(.led).label == "MagSafe LED control is unavailable on this Mac.")
        #expect(Warning.batteryUnreadable.label == "Can't read the battery state.")
    }

    @Test func ledModeLabelAndClickOrder() {
        #expect(LEDMode.auto.label == "Auto")
        #expect(LEDMode.off.label == "Off")
        #expect(LEDMode.auto.next == .off)
        #expect(LEDMode.off.next == .auto)
    }

    @Test func isUnavailable() {
        var status = status(.atLimit)
        status.warnings = [.unavailable(.led)]
        #expect(status.isUnavailable(.led))
        #expect(!status.isUnavailable(.chargeLimit))
    }
}

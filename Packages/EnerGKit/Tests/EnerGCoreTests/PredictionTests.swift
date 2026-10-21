import Testing
@testable import EnerGCore

struct PredictionTests {
    /// Paused at `percent`, as before a Resume; macOS charges by default.
    private func paused(_ percent: Int, charging: Bool = true) -> Status {
        reported(Settings(paused: true), percent: percent, charging: charging)
    }

    private func resumed(_ status: Status) -> Status {
        var settings = status.settings
        settings.paused = false
        return status.predicted(settings: settings, toppingUp: false, chargingBefore: status.snapshot!.isCharging)
    }

    @Test func resumeDerivesTheStateFromBatteryAndLimit() {
        #expect(resumed(paused(85)).stateLabel == "Draining to 80%")
        #expect(resumed(paused(85)).effectiveLimit == 80)
        #expect(resumed(paused(80)).stateLabel == "Holding at 80%")
        #expect(resumed(paused(70, charging: false)).stateLabel == "Charging")
    }

    @Test func bandKeepsTheChargingStateFromBefore() {
        #expect(resumed(paused(77)).stateLabel == "Charging")
        #expect(resumed(paused(77, charging: false)).stateLabel == "Not charging · resumes below 75%")
    }

    @Test func pauseAndTopUp() {
        let holding = reported(percent: 80)
        var settings = holding.settings
        settings.paused = true
        let pausing = holding.predicted(settings: settings, toppingUp: true, chargingBefore: false)
        #expect(pausing.state == .paused)
        #expect(pausing.effectiveLimit == nil)
        #expect(!pausing.toppingUp)
        let toppingUp = holding.predicted(settings: holding.settings, toppingUp: true, chargingBefore: false)
        #expect(toppingUp.state == .toppingUp)
        #expect(toppingUp.effectiveLimit == nil)
    }

    @Test func topUpWhileUnpluggedEndsAtOnce() {
        let unplugged = reported(percent: 70, plugged: false)
        let predicted = unplugged.predicted(settings: unplugged.settings, toppingUp: true, chargingBefore: false)
        #expect(!predicted.toppingUp)
        #expect(predicted.state == .onBattery)
    }

    @Test func lowLimitPredictsTheFallbackOnceItIsKnown() {
        var settings = Settings(chargeLimit: 60)
        let unknown = reported(percent: 85).predicted(settings: settings, toppingUp: false, chargingBefore: false)
        #expect(unknown.effectiveLimit == 60)
        #expect(unknown.stateLabel == "Draining to 60%")
        let fallenBack = reported(Settings(chargeLimit: 70), percent: 85, warnings: [.lowLimitUnsupported])
        let known = fallenBack.predicted(settings: settings, toppingUp: false, chargingBefore: false)
        #expect(known.effectiveLimit == 80)
        #expect(known.warnings == [.lowLimitUnsupported])
        #expect(known.stateLabel == "Draining to 80%")
        settings.chargeLimit = 90
        #expect(fallenBack.predicted(settings: settings, toppingUp: false, chargingBefore: false).warnings.isEmpty)
    }

    @Test func noLimitAndUnreadable() {
        let full = reported(percent: 100)
        let noLimit = full.predicted(settings: Settings(chargeLimit: 100), toppingUp: false, chargingBefore: false)
        #expect(noLimit.effectiveLimit == nil)
        #expect(noLimit.state == .atLimit)
        let unreadable = Status(state: .unknown, settings: Settings(), snapshot: nil, effectiveLimit: nil,
                                toppingUp: false, warnings: [.batteryUnreadable])
        #expect(unreadable.predicted(settings: Settings(), toppingUp: false, chargingBefore: false).state == .unknown)
    }
}

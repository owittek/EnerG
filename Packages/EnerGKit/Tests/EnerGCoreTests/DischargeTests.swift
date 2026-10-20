import Testing
@testable import EnerGCore

struct DischargeTests {
    /// Engine at 92 %, plugged in, Auto-Discharge already running (writes cleared).
    func dischargingAt92(_ settings: Settings = Settings()) -> (Engine, FakeHardware) {
        let (engine, hw) = started(settings)
        hw.snap.percent = 92
        hw.snap.isCharging = false
        engine.handle(.powerChanged)
        hw.writes.removeAll()
        return (engine, hw)
    }

    @Test func autoDischargeCutsAdapterUntilLimit() {
        let (engine, hw) = started()
        hw.snap.percent = 92
        hw.snap.isCharging = false
        var status = engine.handle(.powerChanged)
        #expect(hw.writes == [.adapter(false), .led(.off), .preventSleep(true)])
        #expect(status.state == .discharging)
        #expect(status.dischargeTarget == 80)

        hw.writes.removeAll()
        hw.snap.percent = 80
        hw.snap.adapterConnected = false      // CHIE=08 hides the adapter
        hw.snap.batteryWatts = -15
        status = engine.handle(.tick)
        #expect(hw.writes == [.adapter(true), .led(.system), .preventSleep(false)])
        #expect(status.dischargeTarget == nil)

        hw.writes.removeAll()
        hw.snap.adapterConnected = true
        hw.snap.batteryWatts = 0
        status = engine.handle(.powerChanged)
        #expect(hw.writes == [.led(.green)])
        #expect(status.state == .atLimit)
    }

    @Test func autoDischargeOffHoldsAboveLimit() {
        let (engine, hw) = started(Settings(autoDischarge: false))
        hw.snap.percent = 92
        hw.snap.isCharging = false
        let status = engine.handle(.powerChanged)
        #expect(hw.writes == [.led(.green)])
        #expect(status.state == .atLimit)
    }

    @Test func blinkModeBlinksDuringDischarge() {
        let (engine, hw) = started(Settings(ledMode: .blink))
        hw.snap.percent = 92
        hw.snap.isCharging = false
        engine.handle(.powerChanged)
        #expect(hw.writes == [.adapter(false), .led(.blinkSlow), .preventSleep(true)])
    }

    @Test func manualDischargeRunsToTarget() {
        let (engine, hw) = started()
        var status = engine.handle(.command(.discharge(to: 50)))
        #expect(hw.writes == [.adapter(false), .led(.off), .preventSleep(true)])
        #expect(status.dischargeTarget == 50)

        hw.writes.removeAll()
        hw.snap.percent = 50
        hw.snap.adapterConnected = false
        status = engine.handle(.tick)
        #expect(hw.writes == [.adapter(true), .led(.system), .preventSleep(false)])
        #expect(status.dischargeTarget == nil)
    }

    @Test func manualDischargeAtOrAboveCurrentPercentOrOutOfRangeIsNoop() {
        let (engine, hw) = started()   // 70 %
        engine.handle(.command(.discharge(to: 70)))
        engine.handle(.command(.discharge(to: 3)))
        engine.handle(.command(.discharge(to: 101)))
        #expect(hw.writes.isEmpty)
    }

    @Test func cancelSuppressesAutoDischargeUntilUnplug() {
        let (engine, hw) = dischargingAt92()
        var status = engine.handle(.command(.cancelDischarge))
        #expect(hw.writes == [.adapter(true), .limit(nil), .limit(80), .led(.green), .preventSleep(false)])
        #expect(status.state == .atLimit)

        hw.writes.removeAll()
        engine.handle(.tick)
        #expect(hw.writes.isEmpty)

        hw.snap.adapterConnected = false
        engine.handle(.powerChanged)
        #expect(hw.writes == [.led(.system)])

        hw.writes.removeAll()
        hw.snap.adapterConnected = true
        status = engine.handle(.powerChanged)
        #expect(hw.writes == [.adapter(false), .led(.off), .preventSleep(true)])
        #expect(status.state == .discharging)
    }

    @Test func sleepEndsDischargeUntilWake() {
        let (engine, hw) = dischargingAt92()
        engine.handle(.willSleep)
        #expect(hw.writes == [.adapter(true), .limit(nil), .limit(80), .led(.green), .preventSleep(false)])

        hw.writes.removeAll()
        engine.handle(.tick)
        #expect(hw.writes.isEmpty)

        engine.handle(.didWake)   // wake re-asserts the full state, native limit included
        #expect(hw.writes == [.adapter(false), .limit(80), .led(.off), .preventSleep(true)])
    }

    @Test func closedLidEndsAndBlocksDischarge() {
        let (engine, hw) = dischargingAt92()
        engine.handle(.lid(closed: true))
        #expect(hw.writes == [.adapter(true), .limit(nil), .limit(80), .led(.green), .preventSleep(false)])

        hw.writes.removeAll()
        engine.handle(.command(.discharge(to: 50)))
        engine.handle(.tick)
        #expect(hw.writes.isEmpty)

        engine.handle(.lid(closed: false))
        #expect(hw.writes == [.adapter(false), .led(.off), .preventSleep(true)])
    }

    @Test func failedAdapterCutMarksDischargeUnavailable() {
        let (engine, hw) = started()
        hw.failing = [.discharge]
        hw.snap.percent = 92
        hw.snap.isCharging = false
        var status = engine.handle(.powerChanged)
        #expect(hw.writes == [.led(.green)])
        #expect(status.state == .atLimit)
        #expect(status.warnings.contains(.unavailable(.discharge)))

        hw.writes.removeAll()
        status = engine.handle(.command(.discharge(to: 50)))
        engine.handle(.tick)
        #expect(hw.writes.isEmpty)
        #expect(status.dischargeTarget == nil)
    }

    @Test func pauseDuringDischargeReleasesEverything() {
        let (engine, hw) = dischargingAt92()
        let status = engine.handle(.command(.setPaused(true)))
        #expect(hw.writes == [.adapter(true), .limit(nil), .led(.system), .preventSleep(false)])
        #expect(status.state == .paused)
        #expect(status.dischargeTarget == nil)
    }

    @Test func stopDuringDischargeRestoresAdapterAndLED() {
        let (engine, hw) = dischargingAt92()
        let before = engine.settings
        let status = engine.handle(.stop)
        #expect(hw.writes == [.adapter(true), .led(.system), .preventSleep(false)])
        #expect(!hw.writes.contains { if case .limit = $0 { true } else { false } })
        #expect(status.dischargeTarget == nil)
        #expect(engine.settings == before)
    }

    @Test func unreadableBatteryDuringDischargeRestoresAdapter() {
        let (engine, hw) = dischargingAt92()
        hw.snapshotFails = true
        let status = engine.handle(.tick)
        #expect(hw.writes == [.adapter(true), .preventSleep(false)])
        #expect(status.dischargeTarget == nil)
        #expect(status.warnings.contains(.batteryUnreadable))
    }

    // R1: with CHIE back on above the native limit, macOS stays on battery until the limit is re-set.
    @Test func cancelAboveLimitReappliesNativeLimit() {
        let (engine, hw) = dischargingAt92()
        hw.snap.percent = 85
        engine.handle(.tick)
        hw.writes.removeAll()
        engine.handle(.command(.cancelDischarge))
        #expect(hw.writes == [.adapter(true), .limit(nil), .limit(80), .led(.green), .preventSleep(false)])
    }

    @Test func dischargeEndingAtOrBelowLimitDoesNotReapplyLimit() {
        let (engine, hw) = dischargingAt92()
        hw.snap.percent = 80
        engine.handle(.tick)
        #expect(hw.writes == [.adapter(true), .led(.green), .preventSleep(false)])
    }

    @Test func topUpEndingDischargeAboveLimitDoesNotReapplyLimit() {
        let (engine, hw) = dischargingAt92()
        engine.handle(.command(.topUp))   // desired native limit is nil: nothing to re-apply
        #expect(hw.writes == [.adapter(true), .limit(nil), .led(.green), .preventSleep(false)])
    }

    @Test func failedReapplyLeavesLimitOffAndRetries() {
        let (engine, hw) = dischargingAt92()
        hw.failingLimits = [80]
        let status = engine.handle(.command(.cancelDischarge))
        #expect(hw.writes == [.adapter(true), .limit(nil), .led(.green), .preventSleep(false)])
        #expect(!status.warnings.contains(.unavailable(.chargeLimit)))

        hw.failingLimits = []
        hw.writes.removeAll()
        engine.handle(.tick)
        #expect(hw.writes == [.limit(80)])
    }

    @Test func reapplyFailingAgainLatchesChargeLimit() {
        let (engine, hw) = dischargingAt92()
        hw.failingLimits = [80]
        engine.handle(.command(.cancelDischarge))
        hw.writes.removeAll()
        let status = engine.handle(.tick)
        #expect(hw.writes.isEmpty)
        #expect(status.warnings.contains(.unavailable(.chargeLimit)))
    }

    @Test func startClearsAStaleDischarge() {
        let (engine, hw) = started()   // 70 %
        engine.handle(.command(.discharge(to: 50)))
        hw.writes.removeAll()
        let status = engine.handle(.start)
        #expect(hw.writes == [.adapter(true), .adapter(true), .limit(80), .led(.orange), .preventSleep(false)])
        #expect(status.dischargeTarget == nil)
    }
}

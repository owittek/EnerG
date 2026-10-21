import Testing
@testable import EnerGCore

struct TopUpAndWarningsTests {
    @Test func topUpLiftsLimitUntilUnplug() {
        let (engine, hw) = started()
        var status = engine.handle(.command(.topUp))
        #expect(hw.writes == [.limit(nil)])
        #expect(status.state == .toppingUp)

        hw.writes.removeAll()
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        status = engine.handle(.powerChanged)
        #expect(hw.writes == [.limit(80), .led(.system)])
        #expect(status.state == .onBattery)
    }

    @Test func cancelTopUpRestoresLimit() {
        let (engine, hw) = started()
        engine.handle(.command(.topUp))
        hw.writes.removeAll()
        let status = engine.handle(.command(.cancelTopUp))
        #expect(hw.writes == [.limit(80)])
        #expect(status.state == .charging)
    }

    @Test func statusReportsTopUpEvenWhenBatteryUnreadable() {
        let (engine, hw) = started()
        #expect(engine.handle(.command(.topUp)).toppingUp)
        hw.snapshotFails = true
        let status = engine.handle(.tick)
        #expect(status.state == .unknown)
        #expect(status.toppingUp)
        hw.snapshotFails = false
        #expect(!engine.handle(.command(.cancelTopUp)).toppingUp)
    }

    @Test func pausedIgnoresTopUp() {
        let (engine, hw) = started(Settings(paused: true))
        engine.handle(.command(.topUp))
        let status = engine.handle(.tick)
        #expect(hw.writes.isEmpty)
        #expect(status.state == .paused)
        #expect(!status.toppingUp)
    }

    @Test func weakAdapterNeedsTwoConsecutiveDrainingSamples() {
        let (engine, hw) = started()
        hw.snap.batteryWatts = -5
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))
        #expect(engine.handle(.tick).warnings.contains(.weakAdapter))
        hw.snap.batteryWatts = 3
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))
    }

    @Test func weakAdapterCountsOnlyTicks() {
        let (engine, hw) = started()
        hw.snap.batteryWatts = -5
        engine.handle(.tick)
        #expect(!engine.handle(.command(.getStatus)).warnings.contains(.weakAdapter))
        #expect(!engine.handle(.didWake).warnings.contains(.weakAdapter))
        #expect(!engine.handle(.powerChanged).warnings.contains(.weakAdapter))
        #expect(engine.handle(.tick).warnings.contains(.weakAdapter))
    }

    @Test func interleavedChargingSampleResetsWeakCount() {
        let (engine, hw) = started()
        hw.snap.batteryWatts = -5
        engine.handle(.tick)
        hw.snap.batteryWatts = 3
        engine.handle(.tick)
        hw.snap.batteryWatts = -5
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))
        #expect(engine.handle(.tick).warnings.contains(.weakAdapter))
    }

    @Test func failedLEDWriteDisablesOnlyLED() {
        let (engine, hw) = started { $0.failing = [.led] }
        var status = engine.handle(.command(.setLEDMode(.off)))
        #expect(hw.writes.isEmpty)
        #expect(status.warnings == [.unavailable(.led)])
        status = engine.handle(.command(.setLimit(90)))
        #expect(hw.writes == [.limit(90)])
    }

    @Test func failedLimitWriteDisablesOnlyChargeLimit() {
        let (engine, hw) = started { $0.failing = [.chargeLimit] }
        let status = engine.handle(.command(.setLimit(90)))
        #expect(hw.writes.isEmpty)
        #expect(status.warnings == [.unavailable(.chargeLimit)])
        hw.snap.isCharging = false
        engine.handle(.tick)
        #expect(hw.writes == [.led(.green)])
    }

    @Test func pauseWhileUnreadableEndsTopUp() {
        let (engine, hw) = started()
        engine.handle(.command(.topUp))
        hw.snapshotFails = true
        #expect(!engine.handle(.command(.setPaused(true))).toppingUp)

        hw.snapshotFails = false
        hw.writes.removeAll()
        let status = engine.handle(.command(.setPaused(false)))
        #expect(hw.writes == [.limit(80), .led(.orange)])
        #expect(status.state == .charging)
    }

    @Test func latchedFeatureIsNotRetriedEvenOnWake() {
        let (engine, hw) = started { $0.failing = [.led] }
        hw.failing = []
        engine.handle(.command(.setLEDMode(.off)))
        engine.handle(.didWake)
        #expect(!hw.writes.contains { if case .led = $0 { true } else { false } })
        #expect(engine.handle(.tick).warnings.contains(.unavailable(.led)))
    }
}

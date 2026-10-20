import Testing
@testable import EnerGCore

struct EngineBasicsTests {
    @Test func startResetsAdapterFirstThenAppliesEverything() {
        let hw = FakeHardware()
        let engine = Engine(hardware: hw, settings: Settings())
        let status = engine.handle(.start)
        #expect(hw.writes == [.adapter(true), .adapter(true), .limit(80), .led(.orange), .preventSleep(false)])
        #expect(status.state == .charging)
        #expect(status.warnings.isEmpty)
    }

    // A crash mid-Discharge leaves CHIE cut above the native limit: the start must unstick it.
    @Test func startAboveLimitReappliesNativeLimit() {
        let hw = FakeHardware()
        hw.snap.percent = 85
        hw.snap.isCharging = false
        let engine = Engine(hardware: hw, settings: Settings(autoDischarge: false))
        engine.handle(.start)
        #expect(hw.writes == [.adapter(true), .adapter(true), .limit(nil), .limit(80), .led(.green), .preventSleep(false)])
    }

    @Test func wakeAboveLimitReappliesNativeLimit() {
        let (engine, hw) = started(Settings(autoDischarge: false)) {
            $0.snap.percent = 85
            $0.snap.isCharging = false
        }
        engine.handle(.willSleep)
        engine.handle(.didWake)
        #expect(hw.writes == [.adapter(true), .limit(nil), .limit(80), .led(.green), .preventSleep(false)])
    }

    @Test func repeatedEventsWriteNothing() {
        let (engine, hw) = started()
        engine.handle(.tick)
        engine.handle(.powerChanged)
        engine.handle(.command(.getStatus))
        #expect(hw.writes.isEmpty)
    }

    @Test func pluggedInNotChargingIsAtLimitWithGreenLED() {
        let (engine, hw) = started()
        hw.snap.percent = 80
        hw.snap.isCharging = false
        let status = engine.handle(.tick)
        #expect(hw.writes == [.led(.green)])
        #expect(status.state == .atLimit)
    }

    @Test func setLimitAcceptsOnlyAllowedValues() {
        let (engine, hw) = started()
        var status = engine.handle(.command(.setLimit(90)))
        #expect(hw.writes == [.limit(90)])
        #expect(status.settings.chargeLimit == 90)
        hw.writes.removeAll()
        status = engine.handle(.command(.setLimit(87)))
        #expect(hw.writes.isEmpty)
        #expect(status.settings.chargeLimit == 90)
    }

    @Test func limit100DisablesNativeLimit() {
        let (engine, hw) = started()
        engine.handle(.command(.setLimit(100)))
        #expect(hw.writes == [.limit(nil)])
    }

    @Test func pauseReleasesEverythingAndResumeReapplies() {
        let (engine, hw) = started()
        var status = engine.handle(.command(.setPaused(true)))
        #expect(hw.writes == [.limit(nil), .led(.system)])
        #expect(status.state == .paused)
        #expect(engine.settings.paused)
        hw.writes.removeAll()
        status = engine.handle(.command(.setPaused(false)))
        #expect(hw.writes == [.limit(80), .led(.orange)])
        #expect(status.state == .charging)
    }

    @Test func releaseIsPause() {
        let (engine, hw) = started()
        let status = engine.handle(.command(.release))
        #expect(hw.writes == [.limit(nil), .led(.system)])
        #expect(status.state == .paused)
    }

    @Test func releaseIsNotPersisted() {
        let (engine, hw) = started()
        engine.handle(.command(.release))
        #expect(engine.settings.paused == false)
        hw.writes.removeAll()
        #expect(engine.handle(.command(.topUp)).state == .paused)   // released acts exactly like paused
        #expect(hw.writes.isEmpty)

        // Reinstall: a new energd starts from the same settings and is not paused.
        let hw2 = FakeHardware()
        let restarted = Engine(hardware: hw2, settings: engine.settings)
        let status = restarted.handle(.start)
        #expect(status.state == .charging)
        #expect(hw2.writes == [.adapter(true), .adapter(true), .limit(80), .led(.orange), .preventSleep(false)])
    }

    @Test func resumeAfterReleaseReapplies() {
        let (engine, hw) = started()
        engine.handle(.command(.release))
        hw.writes.removeAll()
        let status = engine.handle(.command(.setPaused(false)))
        #expect(status.state == .charging)
        #expect(hw.writes == [.limit(80), .led(.orange)])
    }

    @Test func unpluggedHandsLEDToSystem() {
        let (engine, hw) = started()
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        hw.snap.batteryWatts = -10
        let status = engine.handle(.powerChanged)
        #expect(hw.writes == [.led(.system)])
        #expect(status.state == .onBattery)
        #expect(!status.warnings.contains(.weakAdapter))
    }

    @Test func ledModeOffAndBlink() {
        let (engine, hw) = started()
        engine.handle(.command(.setLEDMode(.off)))
        #expect(hw.writes == [.led(.off)])
        hw.writes.removeAll()
        engine.handle(.command(.setLEDMode(.blink)))
        #expect(hw.writes == [.led(.orange)])   // blink only differs during a Discharge
    }

    @Test func unreadableBatteryWritesNothingAndWarns() {
        let (engine, hw) = started()
        hw.snapshotFails = true
        let status = engine.handle(.tick)
        #expect(hw.writes.isEmpty)
        #expect(status.state == .unknown)
        #expect(status.snapshot == nil)
        #expect(status.warnings.contains(.batteryUnreadable))
    }

    @Test func startWithUnreadableBatteryOnlyEnablesAdapter() {
        let hw = FakeHardware()
        hw.snapshotFails = true
        let engine = Engine(hardware: hw, settings: Settings())
        let status = engine.handle(.start)
        // Once first thing on start, once more because nothing has been applied yet.
        #expect(hw.writes == [.adapter(true), .adapter(true)])
        #expect(status.state == .unknown)
        #expect(status.warnings.contains(.batteryUnreadable))
    }

    @Test func pauseAppliesEvenWhenBatteryUnreadable() {
        let (engine, hw) = started()
        hw.snapshotFails = true
        let status = engine.handle(.command(.setPaused(true)))
        #expect(hw.writes == [.limit(nil), .led(.system)])
        #expect(status.state == .paused)
    }

    @Test func failedAdapterReenableIsRetried() {
        let (engine, hw) = started()
        hw.snap.percent = 92
        hw.snap.isCharging = false
        engine.handle(.powerChanged)          // Auto-Discharge cuts the adapter
        hw.failing = [.discharge]
        hw.writes.removeAll()
        let status = engine.handle(.willSleep)  // adapter-on fails
        #expect(!hw.writes.contains(.adapter(true)))
        #expect(!status.warnings.contains(.unavailable(.discharge)))
        hw.failing = []
        hw.writes.removeAll()
        engine.handle(.tick)
        #expect(hw.writes == [.adapter(true), .limit(nil), .limit(80)])   // 92 % > limit: re-apply the native limit
    }

    @Test func wakeReassertsFullState() {
        let (engine, hw) = started()
        engine.handle(.willSleep)
        #expect(hw.writes.isEmpty)
        engine.handle(.didWake)
        #expect(hw.writes == [.adapter(true), .limit(80), .led(.orange), .preventSleep(false)])
    }

    @Test func failedWriteDuringWakeIsRetriedNotLatched() {
        let (engine, hw) = started()
        engine.handle(.willSleep)
        hw.failing = [.led]
        let status = engine.handle(.didWake)
        #expect(!status.warnings.contains(.unavailable(.led)))
        #expect(hw.writes == [.adapter(true), .limit(80), .preventSleep(false)])

        hw.failing = []
        hw.writes.removeAll()
        engine.handle(.tick)   // wake re-assert incomplete: the next event re-asserts everything
        #expect(hw.writes == [.adapter(true), .limit(80), .led(.orange), .preventSleep(false)])
    }

    @Test func stopWhenIdleHandsLEDToSystem() {
        let (engine, hw) = started()
        let status = engine.handle(.stop)
        // Adapter-on is always written on stop; the native Charge Limit is left alone.
        #expect(hw.writes == [.adapter(true), .led(.system)])
        #expect(status.dischargeTarget == nil)
        #expect(engine.settings == Settings())
    }

    @Test func manualDischargeRejectedWhileUnplugged() {
        let (engine, hw) = started()
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        engine.handle(.tick)
        hw.writes.removeAll()
        let status = engine.handle(.command(.discharge(to: 50)))
        #expect(hw.writes.isEmpty)
        #expect(status.dischargeTarget == nil)
    }
}

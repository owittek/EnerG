import Testing
@testable import EnerGCore

struct LimitTests {
    @Test func limitsBelowEightyAreAccepted() {
        let (engine, hw) = started()
        var status = engine.handle(.command(.setLimit(60)))
        #expect(hw.writes == [.limit(60)])
        #expect(status.settings.chargeLimit == 60)
        #expect(status.effectiveLimit == 60)
        #expect(!status.warnings.contains(.lowLimitUnsupported))
        hw.writes.removeAll()
        status = engine.handle(.command(.setLimit(45)))
        #expect(hw.writes.isEmpty)
        #expect(status.settings.chargeLimit == 60)
    }

    // The heal turns the adapter back on at the next event, so the write is retried then, not latched.
    @Test func adapterCutIsRetriedOnTheNextEvent() {
        let (engine, hw) = started()
        hw.adapterCuts = 1
        var status = engine.handle(.command(.setLimit(60)))
        #expect(hw.writes.isEmpty)
        #expect(!status.warnings.contains(.unavailable(.chargeLimit)))
        status = engine.handle(.tick)
        #expect(hw.writes == [.limit(60), .led(.orange)])
        #expect(status.effectiveLimit == 60)
        #expect(!status.warnings.contains(.unavailable(.chargeLimit)))
    }

    // A broken CHIE must not pulse on every tick.
    @Test func secondAdapterCutInARowLatches() {
        let (engine, hw) = started()
        hw.adapterCuts = 2
        engine.handle(.command(.setLimit(60)))
        let status = engine.handle(.tick)
        #expect(status.warnings.contains(.unavailable(.chargeLimit)))
        hw.writes.removeAll()
        engine.handle(.tick)
        #expect(hw.writes.isEmpty)
    }

    @Test func aSuccessfulWriteResetsTheAdapterCutCount() {
        let (engine, hw) = started()
        hw.adapterCuts = 1
        engine.handle(.command(.setLimit(60)))
        engine.handle(.tick)
        hw.adapterCuts = 1
        engine.handle(.command(.setLimit(65)))
        let status = engine.handle(.tick)
        #expect(status.effectiveLimit == 65)
        #expect(!status.warnings.contains(.unavailable(.chargeLimit)))
    }

    @Test func effectiveLimitFollowsTheDefaultLimit() {
        let (engine, _) = started()
        #expect(engine.handle(.tick).effectiveLimit == 80)
    }

/// Sets 60 on a Mac that clamps it, then ticks until the first rewrite has settled.
    private func unsupported() -> (Engine, FakeHardware) {
        let (engine, hw) = started { $0.acceptsBelow80 = false }
        engine.handle(.command(.setLimit(60)))
        hw.advance(31)
        engine.handle(.tick)
        hw.advance(600)
        engine.handle(.tick)
        hw.advance(31)
        engine.handle(.tick)
        return (engine, hw)
    }

    // Each rewrite may pulse the adapter: wait, retry with backoff, and only then report it.
    @Test func aClampedLimitIsRetriedThenReported() {
        let (engine, hw) = started { $0.acceptsBelow80 = false }
        var status = engine.handle(.command(.setLimit(60)))
        #expect(hw.writes == [.limit(60)])
        #expect(status.effectiveLimit == 60)
        hw.writes.removeAll()
        hw.advance(31)
        status = engine.handle(.tick)
        #expect(hw.writes.isEmpty)
        #expect(status.warnings.isEmpty)
        hw.advance(600)
        engine.handle(.tick)
        #expect(hw.writes == [.limit(60)])
        hw.advance(31)
        status = engine.handle(.tick)
        #expect(status.effectiveLimit == 80)
        #expect(status.warnings == [.lowLimitUnsupported])
    }

    @Test func aLimitChangeClearsUnsupported() {
        let (engine, _) = unsupported()
        let status = engine.handle(.command(.setLimit(85)))
        #expect(status.effectiveLimit == 85)
        #expect(status.warnings.isEmpty)
    }

    // The bug from 2026-10-25: Calibration must neither fall back nor pulse, and must say what is going on.
    @Test func calibrationWarnsAndWritesNothing() {
        let (engine, hw) = started(Settings(chargeLimit: 60))
        hw.calibrating = true
        hw.advance(31)
        var status = engine.handle(.tick)
        #expect(status.warnings == [.calibrating])
        #expect(status.effectiveLimit == 60)
        hw.advance(6 * 3600)
        status = engine.handle(.tick)
        #expect(!hw.writes.contains { if case .limit = $0 { true } else { false } })
        hw.calibrating = false
        status = engine.handle(.tick)
        #expect(status.warnings.isEmpty)
    }

    @Test func noCalibrationWarningWhileUnpluggedPausedOrToppingUp() {
        let (engine, hw) = started(Settings(chargeLimit: 60))
        hw.calibrating = true
        hw.advance(31)
        var status = engine.handle(.tick)
        #expect(status.warnings == [.calibrating])
        status = engine.handle(.command(.topUp))
        #expect(status.warnings.isEmpty)
        engine.handle(.command(.cancelTopUp))
        status = engine.handle(.command(.setPaused(true)))
        #expect(status.warnings.isEmpty)
        engine.handle(.command(.setPaused(false)))
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        status = engine.handle(.powerChanged)
        #expect(status.warnings.isEmpty)
    }

        @Test func aLimitBelowEightySetWhilePluggedInIsNotResetOnALaterPlugIn() {
        let (engine, hw) = started { $0.acceptsBelow80 = false }
        engine.handle(.command(.setLimit(60)))
        hw.writes.removeAll()
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        engine.handle(.powerChanged)
        hw.snap.adapterConnected = true
        engine.handle(.powerChanged)
        #expect(!hw.writes.contains { if case .limit = $0 { true } else { false } })
    }

    @Test func lowLimitUnsupportedSurvivesAWakeReassertWithAFailedWrite() {
        let (engine, hw) = unsupported()
        hw.failing = [.led]
        let status = engine.handle(.didWake)
        #expect(status.effectiveLimit == 80)
        #expect(status.warnings.contains(.lowLimitUnsupported))
    }

    @Test func pluggingInLeavesALimitOfEightyOrMore() {
        let (engine, hw) = started()
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        engine.handle(.powerChanged)
        hw.writes.removeAll()
        hw.snap.adapterConnected = true
        engine.handle(.powerChanged)
        #expect(!hw.writes.contains(.limit(80)))
    }

    @Test func noEffectiveLimitWhenTheLimitIsUnavailable() {
        let (engine, _) = started { $0.failing = [.chargeLimit] }
        let status = engine.handle(.command(.setLimit(60)))
        #expect(status.effectiveLimit == nil)
        #expect(status.warnings == [.unavailable(.chargeLimit)])
    }

    @Test func noEffectiveLimitWhilePausedOrToppingUp() {
        let (engine, _) = started()
        #expect(engine.handle(.command(.topUp)).effectiveLimit == nil)
        #expect(engine.handle(.command(.cancelTopUp)).effectiveLimit == 80)
        #expect(engine.handle(.command(.setPaused(true))).effectiveLimit == nil)
    }

    // Above the limit macOS runs the Mac from the battery itself.
    @Test func aboveTheLimitIsLimitDrain() {
        let (engine, hw) = started()
        hw.snap.percent = 83
        hw.snap.isCharging = false
        hw.snap.batteryWatts = -11
        let status = engine.handle(.tick)
        #expect(status.state == .limitDrain)
        #expect(hw.writes == [.led(.green)])
    }

    // Right after the limit is lowered macOS still reports charging for a moment; that isn't a Limit Drain yet.
    @Test func aboveTheLimitWhileStillChargingIsCharging() {
        let (engine, hw) = started()
        hw.snap.percent = 83
        hw.snap.isCharging = true
        #expect(engine.handle(.tick).state == .charging)
    }

    @Test func limitDrainFollowsTheEffectiveLimit() {
        let (engine, hw) = unsupported()   // 80 in effect
        hw.snap.percent = 70
        hw.snap.isCharging = false
        #expect(engine.handle(.tick).state == .atLimit)

        let (engine2, hw2) = started()
        engine2.handle(.command(.setLimit(60)))
        hw2.snap.percent = 70
        hw2.snap.isCharging = false
        #expect(engine2.handle(.tick).state == .limitDrain)
    }

    @Test func noLimitDrainWhileToppingUpOrUnplugged() {
        let (engine, hw) = started()
        hw.snap.percent = 85
        #expect(engine.handle(.command(.topUp)).state == .toppingUp)
        engine.handle(.command(.cancelTopUp))
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        #expect(engine.handle(.powerChanged).state == .onBattery)
    }
}

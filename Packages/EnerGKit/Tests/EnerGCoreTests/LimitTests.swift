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

    // The fallback is reported, and not retried every tick (each retry may pulse the adapter).
    @Test func sub80FallbackWarnsAndRetriesOnlyOnWakeOrChange() {
        let (engine, hw) = started { $0.acceptsBelow80 = false }
        var status = engine.handle(.command(.setLimit(60)))
        #expect(hw.writes == [.limit(60)])
        #expect(status.effectiveLimit == 80)
        #expect(status.warnings.contains(.lowLimitUnsupported))

        hw.writes.removeAll()
        engine.handle(.tick)
        engine.handle(.powerChanged)
        #expect(hw.writes.isEmpty)

        status = engine.handle(.didWake)
        #expect(hw.writes == [.limit(60), .led(.orange)])
        #expect(status.warnings.contains(.lowLimitUnsupported))

        status = engine.handle(.command(.setLimit(85)))
        #expect(status.effectiveLimit == 85)
        #expect(!status.warnings.contains(.lowLimitUnsupported))
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
        let (engine, hw) = started { $0.acceptsBelow80 = false }
        engine.handle(.command(.setLimit(60)))   // falls back: 80 in effect
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

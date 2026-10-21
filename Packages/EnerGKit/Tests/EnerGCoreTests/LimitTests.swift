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
}

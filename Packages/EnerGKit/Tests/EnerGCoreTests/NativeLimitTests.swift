import Testing
@testable import EnerGCore

struct NativeLimitTests {
    private func make(_ configure: (FakeLimitControls) -> Void = { _ in }) -> (NativeLimit, FakeLimitControls) {
        let controls = FakeLimitControls()
        configure(controls)
        return (NativeLimit(controls: controls), controls)
    }

    /// A cut found and healed before the next `set`, with the heal's own calls cleared.
    private func healCut(_ limit: NativeLimit, _ controls: FakeLimitControls) throws {
        controls.adapterCut = true
        try limit.healAdapter()
        controls.calls.removeAll()
        controls.waits.removeAll()
    }

    @Test func eightyAndAboveUsePowerUI() throws {
        let (limit, controls) = make()
        try limit.set(85)
        #expect(controls.calls == [.setMCL(85)])
    }

    @Test func belowEightyAppliedOnNotify() throws {
        let (limit, controls) = make()
        try limit.set(60)
        #expect(controls.calls == [.override(60), .notify])
    }

    @Test func belowEightyEnablesTheNativeLimitFirstWhenOff() throws {
        let (limit, controls) = make { $0.chlt = nil }
        try limit.set(60)
        #expect(controls.calls == [.setMCL(80), .override(60), .notify])
    }

    @Test func belowEightyPulsesWhenTheBatteryIsSteady() throws {
        let (limit, controls) = make { $0.daemon = .appliesOnPulse }
        try limit.set(60)
        #expect(controls.calls == [.override(60), .notify, .adapter(false), .adapter(true)])
    }

    // The override stays in place: macOS applies it by itself once it stops ignoring limits (Calibration).
    @Test func belowEightyThatNeverTakesKeepsTheOverride() throws {
        let (limit, controls) = make { $0.daemon = .neverApplies }
        try limit.set(60)
        #expect(controls.calls == [.override(60), .notify, .adapter(false), .adapter(true)])
    }

    // During Calibration CHLT stays off even after 80 and the override: a pulse can't help, LimitCheck judges later.
    @Test func belowEightyDoesNotPulseWhileMacOSIgnoresLimits() throws {
        let (limit, controls) = make {
            $0.daemon = .neverApplies
            $0.ignoresLimits = true
        }
        try limit.set(60)
        #expect(controls.calls == [.setMCL(80), .override(60), .notify])
    }

    // Nothing to apply later, so 80 is put in place.
    @Test func belowEightyHoldsEightyWhenTheOverrideWriteFails() throws {
        let (limit, controls) = make { $0.failingOverride = true }
        try limit.set(60)
        #expect(controls.calls == [.setMCL(80)])
        #expect(controls.chlt == 80)
    }

    // The override is written; only the pulse is missing, so the next % change or plug event applies it.
    @Test func aFailedCutKeepsTheOverride() throws {
        let (limit, controls) = make {
            $0.daemon = .appliesOnPulse
            $0.failingCut = true
        }
        try limit.set(60)
        #expect(controls.calls == [.override(60), .notify])
    }

    // After a re-apply CHLT can still read the value from before the disable; the first poll waits it out.
    @Test func reapplyWaitsBeforeTheFirstPoll() throws {
        let (limit, controls) = make {
            $0.chlt = 60
            $0.daemon = .neverApplies
            $0.staleReads = true
        }
        try healCut(limit, controls)
        try limit.set(60)
        #expect(controls.calls == [.setMCL(nil), .setMCL(80), .override(60), .notify, .adapter(false), .adapter(true)])
        #expect(controls.waits.first == 0.25)
    }

    // Unplugged, a pulse does nothing; the plug-in event applies the value.
    @Test func belowEightyUnpluggedDoesNotPulse() throws {
        let (limit, controls) = make {
            $0.daemon = .neverApplies
            $0.plugged = false
        }
        try limit.set(60)
        #expect(controls.calls == [.override(60), .notify])
    }

    // Wake or start with the value already in place: no writes, no pulse.
    @Test func valueAlreadyInEffectWritesNothing() throws {
        let (limit, controls) = make { $0.chlt = 60 }
        try limit.set(60)
        #expect(controls.calls.isEmpty)
    }

    @Test func pulseRetriesTheAdapterReenable() throws {
        let (limit, controls) = make {
            $0.daemon = .appliesOnPulse
            $0.failingEnables = 2
        }
        try limit.set(60)
        #expect(controls.calls == [.override(60), .notify, .adapter(false), .adapter(true)])
    }

    // The snapshot's heal turns the adapter back on; the next set must then re-apply.
    @Test func adapterStaysCutThrowsAndTheNextSetReapplies() throws {
        let (limit, controls) = make {
            $0.daemon = .appliesOnPulse
            $0.failingEnables = 3
        }
        #expect(throws: HardwareError.adapterCut) { try limit.set(60) }
        #expect(controls.calls == [.override(60), .notify, .adapter(false)])
        controls.calls.removeAll()
        try limit.set(60)
        #expect(controls.calls.first == .setMCL(nil))
    }

    // System Settings must never be left holding a value it can't show.
    @Test func disablingRestoresEightyFirst() throws {
        let (limit, controls) = make { $0.chlt = 60 }
        try limit.set(nil)
        #expect(controls.calls == [.setMCL(80), .setMCL(nil)])
    }

    @Test func disablingAtEightyOrAboveJustDisables() throws {
        let (limit, controls) = make()
        try limit.set(nil)
        #expect(controls.calls == [.setMCL(nil)])
    }

    // A cut left behind (crash mid-pulse) above the limit keeps macOS on battery until the limit is disabled and set again.
    @Test func healedCutDisablesBeforeTheNextSetOnly() throws {
        let (limit, controls) = make()
        try healCut(limit, controls)
        try limit.set(80)
        #expect(controls.calls == [.setMCL(nil), .setMCL(80)])
        controls.calls.removeAll()
        try limit.set(85)
        #expect(controls.calls == [.setMCL(85)])
    }

    // The CHLT read can lag a write just made, so a stale match must not skip the re-apply.
    @Test func healedCutBelowEightyIgnoresTheStaleReading() throws {
        let (limit, controls) = make { $0.chlt = 60 }
        try healCut(limit, controls)
        try limit.set(60)
        #expect(controls.calls == [.setMCL(nil), .setMCL(80), .override(60), .notify])
    }

    // The daemon can take a moment: applied within the settle window means no pulse.
    @Test func belowEightyAppliedWithinTheSettleWindowNeedsNoPulse() throws {
        let (limit, controls) = make { $0.daemon = .appliesAfterWaits(3) }
        try limit.set(60)
        #expect(controls.calls == [.override(60), .notify])
        #expect(controls.waits == [0.25, 0.25, 0.25])
    }

    @Test func eachPollWindowLastsTheSettleTime() throws {
        let (limit, controls) = make { $0.daemon = .neverApplies }
        try limit.set(60)
        let poll = Array(repeating: 0.25, count: 8)
        #expect(controls.waits == poll + [1] + poll)
    }

    // The re-apply disable turns the limit off, so the value from before it decides whether 80 goes back first.
    @Test func healedCutThenDisableRestoresEightyFirst() throws {
        let (limit, controls) = make { $0.chlt = 60 }
        try healCut(limit, controls)
        try limit.set(nil)
        #expect(controls.calls == [.setMCL(nil), .setMCL(80), .setMCL(nil)])
    }

    @Test func healLeavesAWorkingAdapterAlone() throws {
        let (limit, controls) = make()
        try limit.healAdapter()
        #expect(controls.calls.isEmpty)
        #expect(controls.waits.isEmpty)
        try limit.set(85)
        #expect(controls.calls == [.setMCL(85)])
    }

    @Test func healTurnsACutAdapterBackOnAfterASecondRead() throws {
        let (limit, controls) = make { $0.adapterCut = true }
        try limit.healAdapter()
        #expect(controls.calls == [.adapter(true)])
        #expect(controls.waits == [0.25])
        #expect(!controls.adapterCut)
    }

    // A read straight after a pulse's re-enable can return the old value.
    @Test func healIgnoresACutReadingThatClearsAMomentLater() throws {
        let (limit, controls) = make { $0.staleCutReads = 1 }
        try limit.healAdapter()
        #expect(controls.calls.isEmpty)
        #expect(controls.waits == [0.25])
        try limit.set(85)
        #expect(controls.calls == [.setMCL(85)])
    }

    @Test func healThatCantReenableThrowsAndTheNextSetStillReapplies() throws {
        let (limit, controls) = make {
            $0.adapterCut = true
            $0.failingEnables = 1
        }
        #expect(throws: HardwareError.self) { try limit.healAdapter() }
        #expect(controls.calls.isEmpty)
        try limit.set(80)
        #expect(controls.calls == [.setMCL(nil), .setMCL(80)])
    }

    @Test func powerUIFailureThrows() {
        let (limit, _) = make { $0.failingMCL = true }
        #expect(throws: HardwareError.self) { try limit.set(85) }
    }
}

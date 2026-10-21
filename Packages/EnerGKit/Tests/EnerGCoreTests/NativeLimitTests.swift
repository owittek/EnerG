import Testing
@testable import EnerGCore

struct NativeLimitTests {
    private func make(_ configure: (FakeLimitControls) -> Void = { _ in }) -> (NativeLimit, FakeLimitControls) {
        let controls = FakeLimitControls()
        configure(controls)
        return (NativeLimit(controls: controls), controls)
    }

    @Test func eightyAndAboveUsePowerUI() throws {
        let (limit, controls) = make()
        #expect(try limit.set(85) == 85)
        #expect(controls.calls == [.setMCL(85)])
    }

    @Test func belowEightyAppliedOnNotify() throws {
        let (limit, controls) = make()
        #expect(try limit.set(60) == 60)
        #expect(controls.calls == [.override(60), .notify])
    }

    @Test func belowEightyEnablesTheNativeLimitFirstWhenOff() throws {
        let (limit, controls) = make { $0.chlt = nil }
        #expect(try limit.set(60) == 60)
        #expect(controls.calls == [.setMCL(80), .override(60), .notify])
    }

    @Test func belowEightyPulsesWhenTheBatteryIsSteady() throws {
        let (limit, controls) = make { $0.daemon = .appliesOnPulse }
        #expect(try limit.set(60) == 60)
        #expect(controls.calls == [.override(60), .notify, .adapter(false), .adapter(true)])
    }

    @Test func belowEightyFallsBackToEightyWhenItNeverTakes() throws {
        let (limit, controls) = make { $0.daemon = .neverApplies }
        #expect(try limit.set(60) == 80)
        #expect(controls.calls == [.override(60), .notify, .adapter(false), .adapter(true), .setMCL(80)])
        #expect(controls.chlt == 80)
    }

    @Test func belowEightyFallsBackWhenTheOverrideWriteFails() throws {
        let (limit, controls) = make { $0.failingOverride = true }
        #expect(try limit.set(60) == 80)
        #expect(controls.calls == [.setMCL(80)])
    }

    // Unplugged, a pulse does nothing; the plug-in event applies the value.
    @Test func belowEightyUnpluggedIsReturnedUnverified() throws {
        let (limit, controls) = make {
            $0.daemon = .neverApplies
            $0.plugged = false
        }
        #expect(try limit.set(60) == 60)
        #expect(controls.calls == [.override(60), .notify])
    }

    // Wake or start with the value already in place: no writes, no pulse.
    @Test func valueAlreadyInEffectWritesNothing() throws {
        let (limit, controls) = make { $0.chlt = 60 }
        #expect(try limit.set(60) == 60)
        #expect(controls.calls.isEmpty)
    }

    @Test func pulseRetriesTheAdapterReenable() throws {
        let (limit, controls) = make {
            $0.daemon = .appliesOnPulse
            $0.failingEnables = 2
        }
        #expect(try limit.set(60) == 60)
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
        #expect(try limit.set(60) == 60)
        #expect(controls.calls.first == .setMCL(nil))
    }

    // The override is already written; only the pulse is missing, so this is a fallback, not a failure.
    @Test func aFailedCutFallsBackToEighty() throws {
        let (limit, controls) = make {
            $0.daemon = .appliesOnPulse
            $0.failingCut = true
        }
        #expect(try limit.set(60) == 80)
        #expect(controls.calls == [.override(60), .notify, .setMCL(80)])
    }

    // System Settings must never be left holding a value it can't show.
    @Test func disablingRestoresEightyFirst() throws {
        let (limit, controls) = make { $0.chlt = 60 }
        #expect(try limit.set(nil) == nil)
        #expect(controls.calls == [.setMCL(80), .setMCL(nil)])
    }

    @Test func disablingAtEightyOrAboveJustDisables() throws {
        let (limit, controls) = make()
        #expect(try limit.set(nil) == nil)
        #expect(controls.calls == [.setMCL(nil)])
    }

    // A cut left behind (crash mid-pulse) above the limit keeps macOS on battery until the limit is disabled and set again.
    @Test func adapterWasCutDisablesBeforeTheNextSetOnly() throws {
        let (limit, controls) = make()
        limit.adapterWasCut()
        #expect(try limit.set(80) == 80)
        #expect(controls.calls == [.setMCL(nil), .setMCL(80)])
        controls.calls.removeAll()
        #expect(try limit.set(85) == 85)
        #expect(controls.calls == [.setMCL(85)])
    }

    // The CHLT read can lag a write just made, so a stale match must not skip the re-apply.
    @Test func adapterWasCutBelowEightyIgnoresTheStaleReading() throws {
        let (limit, controls) = make { $0.chlt = 60 }
        limit.adapterWasCut()
        #expect(try limit.set(60) == 60)
        #expect(controls.calls == [.setMCL(nil), .setMCL(80), .override(60), .notify])
    }

    // The daemon can take a moment: applied within the settle window means no pulse.
    @Test func belowEightyAppliedWithinTheSettleWindowNeedsNoPulse() throws {
        let (limit, controls) = make { $0.daemon = .appliesAfterWaits(3) }
        #expect(try limit.set(60) == 60)
        #expect(controls.calls == [.override(60), .notify])
        #expect(controls.waits == [0.25, 0.25, 0.25])
    }

    @Test func eachPollWindowLastsTheSettleTime() throws {
        let (limit, controls) = make { $0.daemon = .neverApplies }
        _ = try limit.set(60)
        let poll = Array(repeating: 0.25, count: 8)
        #expect(controls.waits == poll + [1] + poll)
    }

    // After a re-apply CHLT can still read the value from before the disable; the first poll waits it out.
    @Test func reapplyWaitsBeforeTheFirstPoll() throws {
        let (limit, controls) = make {
            $0.chlt = 60
            $0.daemon = .neverApplies
            $0.staleReads = true
        }
        limit.adapterWasCut()
        #expect(try limit.set(60) == 80)
        #expect(controls.calls.last == .setMCL(80))
    }

    // The re-apply disable turns the limit off, so the value from before it decides whether 80 goes back first.
    @Test func adapterWasCutThenDisableRestoresEightyFirst() throws {
        let (limit, controls) = make { $0.chlt = 60 }
        limit.adapterWasCut()
        #expect(try limit.set(nil) == nil)
        #expect(controls.calls == [.setMCL(nil), .setMCL(80), .setMCL(nil)])
    }

    @Test func powerUIFailureThrows() {
        let (limit, _) = make { $0.failingMCL = true }
        #expect(throws: HardwareError.self) { try limit.set(85) }
    }
}

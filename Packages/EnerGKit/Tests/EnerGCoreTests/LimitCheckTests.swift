import Foundation
import Testing
@testable import EnerGCore

struct LimitCheckTests {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func snap(chlt: Int?, plugged: Bool = true) -> BatterySnapshot {
        BatterySnapshot(percent: 62, isCharging: true, adapterConnected: plugged, adapterWatts: 70,
                        batteryWatts: 40, systemWatts: 20, firmwareLimit: chlt)
    }

    /// A check that wrote `requested` at t0 and saw it settle on `chlt` 31 s later.
    private func settled(_ requested: Int, chlt: Int?) -> (LimitCheck, Bool) {
        var check = LimitCheck()
        check.wrote(at: t0)
        _ = check.observe(requested: requested, snapshot: snap(chlt: chlt), now: t0)
        let rewrite = check.observe(requested: requested, snapshot: snap(chlt: chlt), now: t0 + 31)
        return (check, rewrite)
    }

    /// A check that settled 60 on 80, rewrote it once, and now judges it unsupported (at t0 + 662).
    private func unsupported() -> LimitCheck {
        var (check, _) = settled(60, chlt: 80)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 631)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 662)
        return check
    }

    @Test func aMatchIsOK() {
        let (check, rewrite) = settled(60, chlt: 60)
        #expect(check.verdict == .ok)
        #expect(!rewrite)
    }

    @Test func readsWithinTheSettleWindowAreNotJudged() {
        var check = LimitCheck()
        check.wrote(at: t0)
        let rewrite = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 29)
        #expect(check.verdict == .none)
        #expect(!rewrite)
    }

    // macOS ignores every limit during Calibration: nothing to write.
    @Test func offIsCalibratingAndNeverRewrites() {
        var (check, _) = settled(60, chlt: nil)
        #expect(check.verdict == .calibrating)
        let rewrite = check.observe(requested: 60, snapshot: snap(chlt: nil), now: t0 + 6 * 3600)
        #expect(!rewrite)
        #expect(check.verdict == .calibrating)
    }

    @Test func calibrationEndingWithTheLimitAppliedIsOK() {
        var (check, _) = settled(60, chlt: nil)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 60), now: t0 + 3600)
        #expect(check.verdict == .ok)
    }

    // A rewrite made before Calibration doesn't count once it ends: the first mismatch after it is retried.
    @Test func calibrationClearsTheRetries() {
        var (check, _) = settled(60, chlt: 80)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 631)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 60, snapshot: snap(chlt: nil), now: t0 + 662)
        #expect(check.verdict == .calibrating)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 3600)
        #expect(check.verdict == .mismatch(80))
    }

    @Test func aMismatchRewritesAfterTenMinutesThenIsUnsupported() {
        var (check, first) = settled(60, chlt: 80)
        #expect(check.verdict == .mismatch(80))
        #expect(!first)
        let early = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 31 + 599)
        #expect(!early)
        let due = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 31 + 600)
        #expect(due)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 631 + 31)
        #expect(check.verdict == .unsupported(80))
    }

    // At 80 and above a mismatch is never unsupported, so it keeps retrying.
    @Test func retriesBackOffToEveryHundredSixtyMinutes() {
        var (check, _) = settled(85, chlt: 80)
        var now = t0 + 31
        var gaps: [TimeInterval] = []
        for _ in 0..<6 {
            let start = now
            var rewrite = false
            while !rewrite {
                now += 30
                rewrite = check.observe(requested: 85, snapshot: snap(chlt: 80), now: now)
            }
            check.wrote(at: now)
            gaps.append(now.timeIntervalSince(start))
            now += 30
            _ = check.observe(requested: 85, snapshot: snap(chlt: 80), now: now)
        }
        // Each delay starts at the first settled read after a rewrite; the 30 s reads land on it exactly.
        #expect(gaps.map { $0 / 60 } == [10, 20, 40, 80, 160, 160])
    }

    // Each rewrite may pulse the adapter: once a limit below 80 is unsupported, the override stays and only a plug-in,
    // a limit change or a wake writes it again.
    @Test func unsupportedStopsTheTimedRetries() {
        var check = unsupported()
        #expect(check.verdict == .unsupported(80))
        var rewrites = 0
        var now = t0 + 662
        while now < t0 + 662 + 24 * 3600 {
            now += 30
            if check.observe(requested: 60, snapshot: snap(chlt: 80), now: now) { rewrites += 1 }
        }
        #expect(rewrites == 0)
        #expect(check.verdict == .unsupported(80))
    }

    @Test func aPlugInAfterUnsupportedRetriesAgain() {
        var check = unsupported()
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80, plugged: false), now: t0 + 700)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 800)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 831)
        #expect(check.verdict == .mismatch(80))
        let early = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 831 + 599)
        #expect(!early)
        let due = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 831 + 600)
        #expect(due)
    }

    // At 80 and above PowerUI sets the limit itself; a mismatch retries but never claims "doesn't accept".
    @Test func eightyAndAboveNeverClaimUnsupported() {
        var (check, _) = settled(85, chlt: 80)
        _ = check.observe(requested: 85, snapshot: snap(chlt: 80), now: t0 + 31 + 600)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 85, snapshot: snap(chlt: 80), now: t0 + 662)
        #expect(check.verdict == .mismatch(80))
    }

    @Test func aMatchAfterUnsupportedClearsTheRetries() {
        var (check, _) = settled(60, chlt: 80)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 631)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 662)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 60), now: t0 + 700)
        #expect(check.verdict == .ok)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 730)
        #expect(check.verdict == .mismatch(80))
    }

    // A retry's own write must not flicker the tile away.
    @Test func theVerdictHoldsThroughARewritesSettleWindow() {
        var (check, _) = settled(60, chlt: 80)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 631)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 662)
        check.wrote(at: t0 + 2000)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 70), now: t0 + 2001)
        #expect(check.verdict == .unsupported(80))
    }

    @Test func unpluggedPausedOrToppingUpHasNoVerdict() {
        var (check, _) = settled(60, chlt: nil)
        _ = check.observe(requested: 60, snapshot: snap(chlt: nil, plugged: false), now: t0 + 100)
        #expect(check.verdict == .none)
        (check, _) = settled(60, chlt: nil)
        _ = check.observe(requested: nil, snapshot: snap(chlt: nil), now: t0 + 100)
        #expect(check.verdict == .none)
        (check, _) = settled(60, chlt: nil)
        _ = check.observe(requested: 60, snapshot: nil, now: t0 + 100)
        #expect(check.verdict == .none)
    }

    // The daemon applies the override on the plug event itself; its reads can lag, so a plug-in waits it out.
    @Test func aPlugInStartsFreshAndWaitsTheSettleWindow() {
        var (check, _) = settled(60, chlt: 80)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80, plugged: false), now: t0 + 100)
        _ = check.observe(requested: 60, snapshot: snap(chlt: nil), now: t0 + 200)
        #expect(check.verdict == .none)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 60), now: t0 + 231)
        #expect(check.verdict == .ok)
    }

    @Test func aLimitChangeStartsFresh() {
        var (check, _) = settled(60, chlt: 80)
        _ = check.observe(requested: 65, snapshot: snap(chlt: 80), now: t0 + 100)
        #expect(check.verdict == .none)
    }
}

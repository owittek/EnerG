# Calibration and Limit Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Charge Limit below 80 no longer falls back to 80 for good when macOS ignores limits for a while (Calibration). EnerG judges from `CHLT` whether the limit took, retries with backoff, and explains Calibration in the popover.

**Architecture:** `BatterySnapshot` gains `firmwareLimit` (`CHLT` byte 0). A new pure `LimitCheck` turns snapshots into a verdict (`none/ok/calibrating/mismatch/unsupported`) and decides when to write again. `Actuator` writes and asks `LimitCheck`. `Engine` builds warnings and `effectiveLimit` from the verdict. `NativeLimit.set` and `Hardware.setChargeLimit` only write and return nothing. The override is never wiped after a failed check.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI app (XcodeGen), macOS 27.

Spec: `docs/superpowers/specs/2026-10-25-energ-calibration-design.md`.

## Global Constraints

- Branch `calibration` off `main` in the main checkout (no worktree). Task 1 creates it and commits the spec and this plan first.
- Tests: `swift test --package-path Packages/EnerGKit` (repo root). Build: `xcodegen generate && xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug -derivedDataPath build -allowProvisioningUpdates build -quiet` (repo root). Every task ends with tests passing. Tasks touching `EnerG/`, `energd/` or a public EnerGCore API also build.
- Copy, exact: the calibration tile title is "Charge Limit paused by macOS". Its detail is "macOS is calibrating the battery and ignores charge limits until it's done. EnerG switches back to \(limit)% as soon as it can.", with `limit` = `settings.chargeLimit`. The unsupported text stays "This Mac doesn't accept limits below 80%. Holding at 80%.". Apostrophes are U+0027.
- Timings: stale-read window 30 s; retries after 10, 20, 40, 80, then every 160 min.
- Commits: repo style lower case (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`); **never** Co-Authored-By or any AI attribution. Stage files by path. Never commit `build/` or `EnerG.xcodeproj`. Never run sudo.
- Comments: short contract doc comments, ~120 columns, matching surrounding code.
- Keep mutating calls out of `#expect(...)`.

## File Structure

- Create `Packages/EnerGKit/Sources/EnerGCore/LimitCheck.swift`: the verdict and retry schedule (pure value type).
- Create `Packages/EnerGKit/Tests/EnerGCoreTests/LimitCheckTests.swift`.
- Modify `Model.swift` (`BatterySnapshot.firmwareLimit`, `Warning.calibrating`), `NativeLimit.swift`, `Hardware.swift`, `Actuator.swift`, `Engine.swift`, `Prediction.swift`, `Labels.swift`, `Protocol.swift` (doc only), `EnerGMac/MacHardware.swift`, `energ-smoke/main.swift`, `EnerG/PopoverView.swift`.
- Tests: `FakeHardware.swift`, `NativeLimitTests.swift`, `LimitTests.swift`, `ProtocolTests.swift`, `PredictionTests.swift`, `LabelTests.swift`, `StatusFixtures.swift`.
- Docs: `CONTEXT.md`, `docs/adr/0001-sub-80-limits-via-smartcharging-override.md`.

---

### Task 1: Branch, and `BatterySnapshot.firmwareLimit`

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Model.swift` (`BatterySnapshot`)
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift` (`snapshot()`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces: `BatterySnapshot.firmwareLimit: Int?` (nil when `CHLT` is off or unreadable). New trailing init parameter `firmwareLimit: Int? = nil`.

- [ ] **Step 1: Branch and commit the docs**

```bash
git switch -c calibration
git add docs/superpowers/specs/2026-10-25-energ-calibration-design.md docs/superpowers/plans/2026-10-25-energ-calibration.md
git commit -m "docs: calibration and limit check design and plan"
```

- [ ] **Step 2: Write the failing test** (append to `ProtocolTests`)

```swift
    @Test func snapshotWithoutFirmwareLimitDecodes() throws {
        let json = #"{"percent":81,"isCharging":false,"adapterConnected":true,"batteryWatts":-5.5,"plugSensed":true}"#
        let snapshot = try JSONDecoder().decode(BatterySnapshot.self, from: Data(json.utf8))
        #expect(snapshot.firmwareLimit == nil)
    }

    @Test func snapshotFirmwareLimitRoundTrips() throws {
        let snapshot = BatterySnapshot(percent: 62, isCharging: true, adapterConnected: true, adapterWatts: 70,
                                       batteryWatts: 40, systemWatts: 20, firmwareLimit: 60)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(BatterySnapshot.self, from: data) == snapshot)
    }
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `swift test --package-path Packages/EnerGKit --filter ProtocolTests`
Expected: compile error, `extra argument 'firmwareLimit'`.

- [ ] **Step 4: Implement**

In `BatterySnapshot` (Model.swift), after `plugSensed`:

```swift
    /// The limit the firmware enforces (SMC `CHLT` byte 0); nil when off or unreadable. Off while a limit is
    /// requested means macOS ignores every limit for now (Calibration).
    public var firmwareLimit: Int?
```

The init becomes `plugSensed: Bool = true, firmwareLimit: Int? = nil` and assigns `self.firmwareLimit = firmwareLimit`. In `init(from:)` add:

```swift
        firmwareLimit = try c.decodeIfPresent(Int.self, forKey: .firmwareLimit)
```

In `MacHardware.snapshot()`, read `CHLT` once and use it for both fields:

```swift
        let chlt = try? read("CHLT", size: 3)
        return BatterySnapshot(
            percent: percent,
            isCharging: BatterySnapshot.isCharging(chlt: chlt, percent: percent,
                                                   adapterConnected: adapterConnected,
                                                   registryIsCharging: p["IsCharging"] as? Bool ?? false),
            adapterConnected: adapterConnected,
            adapterWatts: (adapter?["Watts"] as? NSNumber)?.intValue,
            batteryWatts: liveBatteryWatts() ?? milliamps * millivolts / 1_000_000,
            systemWatts: (try? readFloat("PSTR")).map(Double.init),
            plugSensed: plugged != nil,
            firmwareLimit: chlt.flatMap { $0[0] == 0 ? nil : Int($0[0]) }
        )
```

- [ ] **Step 5: Run tests and confirm they pass**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/Model.swift Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift Packages/EnerGKit/Tests/EnerGCoreTests/ProtocolTests.swift
git commit -m "feat: report the firmware's charge limit in the battery snapshot"
```

---

### Task 2: `LimitCheck`

**Files:**
- Create: `Packages/EnerGKit/Sources/EnerGCore/LimitCheck.swift`
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/LimitCheckTests.swift`

**Interfaces:**
- Consumes: `BatterySnapshot.firmwareLimit` (Task 1), `NativeLimit.powerUIMinimum` (80).
- Produces (internal):
  - `struct LimitCheck`
  - `enum Verdict: Equatable { case none, ok, calibrating, mismatch, unsupported(Int) }`
  - `private(set) var verdict: Verdict`
  - `mutating func wrote(at now: Date)`
  - `mutating func observe(requested: Int?, snapshot: BatterySnapshot?, now: Date) -> Bool`
  - `static let settle: TimeInterval = 30`, `firstRetry = 600`, `maxRetry = 9600`

- [ ] **Step 1: Write the failing tests**

```swift
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

    @Test func aMismatchRewritesAfterTenMinutesThenIsUnsupported() {
        var (check, first) = settled(60, chlt: 80)
        #expect(check.verdict == .mismatch)
        #expect(!first)
        let early = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 31 + 599)
        #expect(!early)
        let due = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 31 + 600)
        #expect(due)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 631 + 31)
        #expect(check.verdict == .unsupported(80))
    }

    @Test func retriesBackOffToEveryHundredSixtyMinutes() {
        var (check, _) = settled(60, chlt: 80)
        var now = t0 + 31
        var gaps: [TimeInterval] = []
        for _ in 0..<6 {
            let start = now
            var rewrite = false
            while !rewrite {
                now += 30
                rewrite = check.observe(requested: 60, snapshot: snap(chlt: 80), now: now)
            }
            check.wrote(at: now)
            gaps.append(now.timeIntervalSince(start))
            now += 30
            _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: now)
        }
        // Each delay starts at the first settled read after a rewrite; the 30 s reads land on it exactly.
        #expect(gaps.map { $0 / 60 } == [10, 20, 40, 80, 160, 160])
    }

    // At 80 and above PowerUI sets the limit itself; a mismatch retries but never claims "doesn't accept".
    @Test func eightyAndAboveNeverClaimUnsupported() {
        var (check, _) = settled(85, chlt: 80)
        _ = check.observe(requested: 85, snapshot: snap(chlt: 80), now: t0 + 31 + 600)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 85, snapshot: snap(chlt: 80), now: t0 + 662)
        #expect(check.verdict == .mismatch)
    }

    @Test func aMatchAfterUnsupportedClearsTheRetries() {
        var (check, _) = settled(60, chlt: 80)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 631)
        check.wrote(at: t0 + 631)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 662)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 60), now: t0 + 700)
        #expect(check.verdict == .ok)
        _ = check.observe(requested: 60, snapshot: snap(chlt: 80), now: t0 + 730)
        #expect(check.verdict == .mismatch)
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
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --package-path Packages/EnerGKit --filter LimitCheckTests`
Expected: compile error, `cannot find 'LimitCheck' in scope`.

- [ ] **Step 3: Implement** `LimitCheck.swift`

```swift
import Foundation

/// Judges from snapshots whether the requested Charge Limit took, and when to write it again. A write alone can't tell:
/// the smartcharging daemon applies a limit below 80 on its next % change or plug event (ADR 0001), and during
/// Calibration macOS ignores every limit and `CHLT` reads off. Not thread-safe: call from the Engine's serial context.
struct LimitCheck {
    enum Verdict: Equatable {
        /// Nothing to judge: no limit requested, unplugged, unreadable, or no settled read yet.
        case none
        case ok
        /// macOS ignores every limit for now (Calibration). Nothing is written: the limit applies once it ends.
        case calibrating
        /// `CHLT` holds another value; `observe` asks for a rewrite once the retry delay has passed.
        case mismatch
        /// A limit below 80 still reads as this value after a rewrite, so this value is in effect.
        case unsupported(Int)
    }

    /// A `CHLT` read this soon after a limit write or a plug-in can show the value from before it.
    static let settle: TimeInterval = 30
    /// Delay before the first rewrite of a mismatch; doubles per rewrite up to `maxRetry`.
    static let firstRetry: TimeInterval = 10 * 60
    static let maxRetry: TimeInterval = 160 * 60

    private(set) var verdict = Verdict.none
    /// The requested limit the verdict and retries belong to; nil while there is nothing to judge.
    private var judged: Int?
    /// Reads before this are not judged.
    private var settledAfter: Date?
    /// Rewrites made since the last match.
    private var retries = 0
    private var retryAt: Date?

    /// A limit write was made at `now`; reads in the next `settle` seconds keep the current verdict.
    mutating func wrote(at now: Date) {
        settledAfter = now + Self.settle
    }

    /// Updates the verdict from a snapshot read at `now`. `requested` is nil while no limit is asked for (off, paused,
    /// topping up, or unavailable). Returns true when the limit should be written again now; the caller then
    /// writes it and calls `wrote(at:)`.
    mutating func observe(requested: Int?, snapshot: BatterySnapshot?, now: Date) -> Bool {
        guard let requested, let snapshot, snapshot.adapterConnected else {
            startFresh(judging: nil)
            return false
        }
        if requested != judged {
            startFresh(judging: requested)
            settledAfter = max(settledAfter ?? now, now + Self.settle)
        }
        if let settledAfter, now < settledAfter { return false }
        guard let held = snapshot.firmwareLimit else {
            verdict = .calibrating
            retryAt = nil
            return false
        }
        if held == requested {
            verdict = .ok
            retries = 0
            retryAt = nil
            return false
        }
        verdict = retries > 0 && requested < NativeLimit.powerUIMinimum ? .unsupported(held) : .mismatch
        guard let due = retryAt else {
            retryAt = now + min(Self.firstRetry * pow(2, Double(retries)), Self.maxRetry)
            return false
        }
        guard now >= due else { return false }
        retries += 1
        retryAt = nil
        return true
    }

    private mutating func startFresh(judging limit: Int?) {
        verdict = .none
        judged = limit
        retries = 0
        retryAt = nil
    }
}
```

- [ ] **Step 4: Run tests and confirm they pass**

Run: `swift test --package-path Packages/EnerGKit --filter LimitCheckTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/LimitCheck.swift Packages/EnerGKit/Tests/EnerGCoreTests/LimitCheckTests.swift
git commit -m "feat: LimitCheck judges from CHLT whether the charge limit took"
```

---

### Task 3: `NativeLimit.set` only writes

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/NativeLimit.swift`
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift` (`setChargeLimit`, temporarily)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/NativeLimitTests.swift`

**Interfaces:**
- Produces: `public func set(_ percent: Int?) throws` (no return value). A failed check after the pulse no longer calls `setMCL(80)`. Only a failed override *write* still calls `setMCL(80)`, so 80 holds.
- Temporary: `MacHardware.setChargeLimit` keeps returning `Int?` (`try nativeLimit.set(percent); return percent`) until Task 4 changes the `Hardware` protocol.

- [ ] **Step 1: Update the tests first**

In `NativeLimitTests`, every `#expect(try limit.set(X) == Y)` becomes `try limit.set(X)` followed by the existing `calls` expectation, and `_ = try limit.set(60)` becomes `try limit.set(60)`. Replace the four fallback tests with these:

```swift
    // The override stays in place: macOS applies it by itself once it stops ignoring limits (Calibration).
    @Test func belowEightyThatNeverTakesKeepsTheOverride() throws {
        let (limit, controls) = make { $0.daemon = .neverApplies }
        try limit.set(60)
        #expect(controls.calls == [.override(60), .notify, .adapter(false), .adapter(true)])
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
```

Remove `belowEightyFallsBackToEightyWhenItNeverTakes`, `belowEightyFallsBackWhenTheOverrideWriteFails`, `aFailedCutFallsBackToEighty` and the old `reapplyWaitsBeforeTheFirstPoll`. Keep `belowEightyUnpluggedIsReturnedUnverified` as `belowEightyUnpluggedDoesNotPulse`, with the body `try limit.set(60)` and the same `calls` expectation. Keep `eachPollWindowLastsTheSettleTime` unchanged except `try limit.set(60)`.

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --package-path Packages/EnerGKit --filter NativeLimitTests`
Expected: failures (unused result warnings, and the new tests fail on the trailing `.setMCL(80)`).

- [ ] **Step 3: Implement**

In `NativeLimit`:

```swift
    /// Sets the limit; nil disables it. Below `powerUIMinimum` the override is written and, when the daemon doesn't
    /// apply it within `settle` while plugged in, a pulse supplies the plug event. Whether it took is judged later
    /// from snapshots (`LimitCheck`): during Calibration macOS ignores every limit, so the override is left in place for
    /// the daemon to apply once it ends. Throws when PowerUI fails, or `HardwareError.adapterCut` when the adapter can't
    /// be turned back on after a pulse. Can block for about 5 s when a pulse is needed, and one poll longer after a
    /// re-apply.
    public func set(_ percent: Int?) throws {
        let reapplying = adapterCut
        // Read before the re-apply disable, which turns the limit off.
        let current = controls.smcLimit()
        if reapplying {
            try controls.setMCL(nil)
            adapterCut = false
        }
        guard let percent else {
            // Leave Apple's domain holding a value System Settings can show.
            if let current, current < Self.powerUIMinimum { try controls.setMCL(Self.powerUIMinimum) }
            try controls.setMCL(nil)
            return
        }
        if percent >= Self.powerUIMinimum {
            try controls.setMCL(percent)
            return
        }
        // A CHLT read straight after a write can return the old value, so after a re-apply it isn't trusted.
        if !reapplying, current == percent { return }
        if reapplying || current == nil { try controls.setMCL(Self.powerUIMinimum) }
        do {
            try controls.writeOverride(percent)
        } catch {
            // Nothing for the daemon to apply later: hold 80.
            try controls.setMCL(Self.powerUIMinimum)
            return
        }
        controls.notifyDefaultsChanged()
        if waitUntilApplied(percent, afterReapply: reapplying) { return }
        guard controls.pluggedIn() else { return }
        // A failed cut leaves the override in place for the next % change or plug event.
        guard try pulse() else { return }
        _ = waitUntilApplied(percent, afterReapply: false)
    }
```

Delete `fallBack()`. Update the `powerUIMinimum` doc to `/// PowerUI's lowest accepted limit; held when the override can't be written.`. Update the type doc's last sentence. Keep "Owns the adapter's `CHIE` lifecycle: the pulse, and the heal of an adapter a pulse left cut."

In `MacHardware`:

```swift
    public func setChargeLimit(_ percent: Int?) throws -> Int? {
        try nativeLimit.set(percent)
        return percent
    }
```

- [ ] **Step 4: Run tests and confirm they pass**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass. `LimitTests` uses `FakeHardware`, which is unchanged so far.

- [ ] **Step 5: Commit**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/NativeLimit.swift Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift Packages/EnerGKit/Tests/EnerGCoreTests/NativeLimitTests.swift
git commit -m "fix: keep the smartcharging override when a limit below 80 doesn't take yet"
```

---

### Task 4: Actuator and Engine judge the limit through `LimitCheck`

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Hardware.swift`, `Actuator.swift`, `Engine.swift`, `Model.swift` (`Warning.calibrating`), `Labels.swift` (label only), `Protocol.swift` (`effectiveLimit` doc), `Policy.swift` (doc of `lowLimitUnsupported`)
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift`, `Packages/EnerGKit/Sources/energ-smoke/main.swift`
- Test: `FakeHardware.swift`, `LimitTests.swift`, `LabelTests.swift`, `StatusFixtures.swift` (unchanged unless it stops compiling)

**Interfaces:**
- Consumes: `LimitCheck` (Task 2), `NativeLimit.set(_:) throws` (Task 3).
- Produces:
  - `Hardware.setChargeLimit(_ percent: Int?) throws`
  - `public init(hardware: any Hardware, settings: Settings, now: @escaping () -> Date = Date.init)` on `Engine`
  - `Warning.calibrating` (label "Charge Limit paused by macOS")
  - `FakeHardware.chlt: Int?`, `FakeHardware.calibrating: Bool`, `FakeHardware.now: Date`, `FakeHardware.advance(_ seconds: TimeInterval)`

- [ ] **Step 1: Make FakeHardware simulate `CHLT` and a clock**

In `FakeHardware`:

```swift
    /// What `CHLT[0]` holds; limit writes land here, clamped to 80 without `acceptsBelow80`.
    var chlt: Int? = 80
    /// macOS ignores every limit (Calibration): snapshots read `CHLT` off.
    var calibrating = false
    /// The Engine's clock (see `started`).
    var now = Date(timeIntervalSince1970: 0)

    func advance(_ seconds: TimeInterval) { now += seconds }

    func snapshot() throws -> BatterySnapshot {
        snapshotCalls += 1
        if snapshotFails { throw HardwareError.io(-1) }
        var s = snap
        s.firmwareLimit = calibrating ? nil : chlt
        return s
    }

    func setChargeLimit(_ percent: Int?) throws {
        if failing.contains(.chargeLimit) { throw HardwareError.notPrivileged }
        if let percent, failingLimits.contains(percent) { throw HardwareError.io(-2) }
        if percent != nil, adapterCuts > 0 {
            adapterCuts -= 1
            throw HardwareError.adapterCut
        }
        writes.append(.limit(percent))
        chlt = percent.map { acceptsBelow80 ? $0 : max($0, 80) }
    }
```

Update the `acceptsBelow80` doc to `/// false: limits below 80 read as 80 in \`CHLT\`, like a macOS that clamps the override.`. Add `import Foundation` at the top. `started` builds the engine with `Engine(hardware: hw, settings: settings, now: { hw.now })`.

- [ ] **Step 2: Rewrite the fallback tests in `LimitTests`**

Remove `sub80FallbackWarnsAndRetriesOnlyOnWakeOrChange`, `pluggingInReverifiesALimitBelowEighty`, `theReverifyHappensOncePerUnverifiedSet` and `aFlickerAfterTheReverifyWritesNoSecondLimit`. Keep `aLimitBelowEightySetWhilePluggedInIsNotResetOnALaterPlugIn` and `pluggingInLeavesALimitOfEightyOrMore` unchanged. Add a helper and tests:

```swift
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
```

Replace `lowLimitUnsupportedSurvivesAWakeReassertWithAFailedWrite`:

```swift
    @Test func lowLimitUnsupportedSurvivesAWakeReassertWithAFailedWrite() {
        let (engine, hw) = unsupported()
        hw.failing = [.led]
        let status = engine.handle(.didWake)
        #expect(status.effectiveLimit == 80)
        #expect(status.warnings.contains(.lowLimitUnsupported))
    }
```

In `limitDrainFollowsTheEffectiveLimit`, replace the first three lines with `let (engine, hw) = unsupported()   // 80 in effect`.

- [ ] **Step 3: Add the label test** (in `LabelTests.warningLabel`)

```swift
        #expect(Warning.calibrating.label == "Charge Limit paused by macOS")
```

- [ ] **Step 4: Run them and confirm they fail**

Run: `swift test --package-path Packages/EnerGKit`
Expected: compile errors: `FakeHardware` doesn't conform to `Hardware`, no `now:` on `Engine`, no `Warning.calibrating`.

- [ ] **Step 5: Implement**

`Hardware.swift`:

```swift
    /// Sets the native Charge Limit; nil disables it. Whether a limit took is judged later from snapshots
    /// (`BatterySnapshot.firmwareLimit`). Throws `HardwareError.adapterCut` when a pulse left the adapter cut.
    func setChargeLimit(_ percent: Int?) throws
```

`Model.swift`, in `Warning`:

```swift
    /// macOS ignores every Charge Limit for now (Calibration); it applies again once that ends.
    case calibrating
```

`Labels.swift`, in `Warning.label`: `case .calibrating: "Charge Limit paused by macOS"`.

`Actuator.swift`, replacing the limit bookkeeping:

```swift
import Foundation

/// Writes an `Actuation` through `Hardware`, only the fields that changed or, for the LED, that macOS changed, and
/// keeps what the writes reported: the Charge Limit written and the Features whose writes failed. Whether the Charge
/// Limit took is judged by `limitCheck`, which can ask for it to be written again. Not thread-safe: call from the
/// Engine's serial context.
final class Actuator {
    private let hardware: any Hardware
    /// Last actuation written; nil means unknown, so everything is written.
    private var applied: Actuation?
    /// The Charge Limit last written successfully; nil when off, failed or not written yet.
    private var writtenLimit: Int?
    /// Features whose write failed; not written again until `reset`.
    private(set) var unavailable: Set<Feature> = []
    /// The last Charge Limit write left the adapter cut; a second one in a row makes it unavailable.
    private var adapterLeftCut = false
    /// A write is to be retried: the next `apply` re-asserts everything.
    private var retryNextApply = false
    private(set) var limitCheck = LimitCheck()

    init(hardware: any Hardware) {
        self.hardware = hardware
    }

    /// The Charge Limit in effect: the one written, or what the firmware holds when a lower one didn't take.
    var effectiveLimit: Int? {
        if case .unsupported(let held) = limitCheck.verdict { return held }
        return writtenLimit
    }

    /// Daemon launch: hardware state is unknown and every Feature is tried again.
    func reset() {
        applied = nil
        writtenLimit = nil
        unavailable = []
        adapterLeftCut = false
        limitCheck = LimitCheck()
    }

    /// Hardware state is unknown, e.g. after sleep: the next `apply` writes everything.
    func forget() {
        applied = nil
    }

    /// Writes what differs from the last `apply`, then lets `limitCheck` judge `snapshot` (read at `now`, before these
    /// writes; nil when unreadable). `retryFailures`: a failed write is retried on the next `apply` instead of making
    /// its Feature unavailable.
    func apply(_ next: Actuation, snapshot: BatterySnapshot?, now: Date, retryFailures: Bool) {
        if changed(\.chargeLimit, to: next) {
            writeLimit(next.chargeLimit, now: now, retryFailures: retryFailures)
        }
        let requested = unavailable.contains(.chargeLimit) ? nil : next.chargeLimit
        if limitCheck.observe(requested: requested, snapshot: snapshot, now: now) {
            writeLimit(next.chargeLimit, now: now, retryFailures: retryFailures)
        }
        if changed(\.led, to: next) || ledDrifted(from: next.led) {
            write(.led, retryFailures: retryFailures) { try hardware.setLED(next.led) }
        }
        applied = next
        if retryNextApply {
            applied = nil
            retryNextApply = false
        }
    }
```

Keep `releaseLED`, `ledDrifted`, `changed` and `write` as they are. Delete `requestedLimit`, `limitUnverified`, `lowLimitUnsupported` and `needsReverify`. Add:

```swift
    private func writeLimit(_ limit: Int?, now: Date, retryFailures: Bool) {
        write(.chargeLimit, retryFailures: retryFailures) {
            writtenLimit = nil
            try hardware.setChargeLimit(limit)
            writtenLimit = limit
        }
        limitCheck.wrote(at: now)
    }
```

`Engine.swift`:
- Add `import Foundation` at the top (it has none yet).
- Add `private let now: () -> Date`, and use the init `public init(hardware: any Hardware, settings: Settings, now: @escaping () -> Date = Date.init)`.
- In `evaluate`, drop `previous`. The failure path calls `actuator.apply(.released, snapshot: nil, now: now(), retryFailures: retryFailures)`. The success path calls `actuator.apply(Policy.actuation(...), snapshot: current, now: now(), retryFailures: retryFailures)`.
- In `status()`, replace the `lowLimitUnsupported` line with:

```swift
        switch actuator.limitCheck.verdict {
        case .calibrating: warnings.append(.calibrating)
        case .unsupported: warnings.append(.lowLimitUnsupported)
        case .none, .ok, .mismatch: break
        }
```

`Protocol.swift`, the `effectiveLimit` doc becomes `/// The native Charge Limit in effect: the setting, or what the firmware holds when a lower one didn't take. nil while off, paused, topping up, or when the Charge Limit is unavailable.`, wrapped at ~120 columns.

`Policy.lowLimitUnsupported` stays, because Prediction uses it. Its doc becomes `/// A Charge Limit below 80 didn't take: more is in effect than was asked for. \`Status.predicted\` uses it.`.

`MacHardware.setChargeLimit`:

```swift
    public func setChargeLimit(_ percent: Int?) throws {
        try nativeLimit.set(percent)
    }
```

`energ-smoke/main.swift`: the two `limit` cases set the limit, then print the same line as `get-limit`:

```swift
    case ("limit", "off"):
        try hw.setChargeLimit(nil)
        print("CHLT=\(hw.smcLimit().map(String.init) ?? "off")")
    case ("limit", _):
        guard let limit = Int(argument), (50...100).contains(limit) else { print(usage); exit(2) }
        try hw.setChargeLimit(limit)
        print("CHLT=\(hw.smcLimit().map(String.init) ?? "off")")   // what the firmware holds now
```

`scripts/smoke.sh` reads `get-limit`, not `limit`'s output: check with `grep -n 'S limit' scripts/smoke.sh` that nothing parses `limit`'s output. If something does, adapt it to the `CHLT=` line.

- [ ] **Step 6: Run tests and build**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.
Run the build command from Global Constraints. Expected: `** BUILD SUCCEEDED **`, or no output with `-quiet` and exit 0.

- [ ] **Step 7: Commit**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/Hardware.swift Packages/EnerGKit/Sources/EnerGCore/Actuator.swift Packages/EnerGKit/Sources/EnerGCore/Engine.swift Packages/EnerGKit/Sources/EnerGCore/Model.swift Packages/EnerGKit/Sources/EnerGCore/Labels.swift Packages/EnerGKit/Sources/EnerGCore/Protocol.swift Packages/EnerGKit/Sources/EnerGCore/Policy.swift Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift Packages/EnerGKit/Sources/energ-smoke/main.swift Packages/EnerGKit/Tests/EnerGCoreTests/FakeHardware.swift Packages/EnerGKit/Tests/EnerGCoreTests/LimitTests.swift Packages/EnerGKit/Tests/EnerGCoreTests/LabelTests.swift
git commit -m "fix: judge the charge limit from CHLT and retry instead of falling back to 80"
```

---

### Task 5: Calibration tile copy, prediction and popover

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Labels.swift` (`Status.detail(for:)`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Prediction.swift`
- Modify: `EnerG/PopoverView.swift` (`NoticeTile`, `NoticeTiles`)
- Test: `LabelTests.swift`, `PredictionTests.swift`

**Interfaces:**
- Consumes: `Warning.calibrating` (Task 4).
- Produces: `public func detail(for warning: Warning) -> String?` on `Status`.

- [ ] **Step 1: Write the failing tests**

`LabelTests`:

```swift
    @Test func calibrationDetailNamesTheLimit() {
        var status = status(.charging)
        status.settings.chargeLimit = 60
        #expect(status.detail(for: .calibrating)
                == "macOS is calibrating the battery and ignores charge limits until it's done. EnerG switches back to 60% as soon as it can.")
        #expect(status.detail(for: .lowLimitUnsupported) == nil)
    }
```

`PredictionTests`:

```swift
    @Test func calibrationStaysWhileALimitIsRequested() {
        let calibrating = reported(Settings(chargeLimit: 60), percent: 62, charging: true, warnings: [.calibrating])
        var settings = calibrating.settings
        settings.chargeLimit = 70
        let changed = calibrating.predicted(settings: settings, toppingUp: false, chargingBefore: true)
        #expect(changed.warnings == [.calibrating])
        // macOS keeps charging past the limit during Calibration.
        #expect(changed.snapshot?.isCharging == true)
        let toppingUp = calibrating.predicted(settings: calibrating.settings, toppingUp: true, chargingBefore: true)
        #expect(toppingUp.warnings.isEmpty)
        settings.paused = true
        let paused = calibrating.predicted(settings: settings, toppingUp: false, chargingBefore: true)
        #expect(paused.warnings.isEmpty)
    }
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --package-path Packages/EnerGKit --filter "LabelTests|PredictionTests"`
Expected: compile error, no `detail(for:)`. The prediction test fails because isCharging is re-derived to false at 62 ≥ 60.

- [ ] **Step 3: Implement**

`Labels.swift`, in the `extension Status` that holds `stateLabel`:

```swift
    /// A second, quieter line under a warning's label; nil when the label says it all.
    public func detail(for warning: Warning) -> String? {
        switch warning {
        case .calibrating:
            "macOS is calibrating the battery and ignores charge limits until it's done. "
                + "EnerG switches back to \(settings.chargeLimit)% as soon as it can."
        case .lowLimitUnsupported, .unavailable, .batteryUnreadable:
            nil
        }
    }
```

`Prediction.swift`: after `requested` is computed:

```swift
        // macOS ignores every limit during Calibration, whatever the new one; it ends on its own.
        let calibrating = requested != nil && plugged && warnings.contains(.calibrating)
```

Then:
- `var newWarnings = warnings.filter { $0 != .lowLimitUnsupported && $0 != .calibrating }`.
- After the `lowLimitUnsupported` insert, add `if calibrating { newWarnings.insert(.calibrating, at: 0) }`.
- The snapshot re-derive condition becomes `if var s = battery, s.adapterConnected, !settings.paused, !calibrating {`.
- Add to the doc comment: "During Calibration the snapshot is kept as is: macOS charges past any limit."

`PopoverView.swift`, `NoticeTile`: add `var detail: String?` after `tint`. In the `VStack`:

```swift
                Text(text).font(.callout)
                    .fontWeight(detail == nil ? nil : .semibold)
                    .foregroundStyle(busy ? .secondary : .primary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
```

`NoticeTiles`:

```swift
            NoticeTile(text: warning.label, symbol: "exclamationmark.triangle.fill", tint: .orange,
                       detail: status.detail(for: warning))
```

- [ ] **Step 4: Run tests and build**

Run: `swift test --package-path Packages/EnerGKit`, then the build command. Expected: all pass, build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/Labels.swift Packages/EnerGKit/Sources/EnerGCore/Prediction.swift EnerG/PopoverView.swift Packages/EnerGKit/Tests/EnerGCoreTests/LabelTests.swift Packages/EnerGKit/Tests/EnerGCoreTests/PredictionTests.swift
git commit -m "feat: explain calibration in the popover"
```

---

### Task 6: Docs

**Files:**
- Modify: `CONTEXT.md`, `docs/adr/0001-sub-80-limits-via-smartcharging-override.md`

- [ ] **Step 1: CONTEXT.md**

After **Limit Drain**, add:

```markdown
**Calibration**:
A macOS battery-gauge recalibration charge (PowerUI `ChargingUpForGauging`) during which macOS ignores every **Charge Limit** and SMC `CHLT` reads off. Started and ended by macOS; EnerG only reports it and leaves the limit in place for macOS to apply afterwards.
_Avoid_: gauging, mitigation
```

Under Relationships, add: `- During **Calibration** the **Charge Limit** is not enforced; it applies again on its own once **Calibration** ends.`

- [ ] **Step 2: ADR 0001**

In Consequences, replace the first bullet with:

```markdown
- The method is undocumented and may break with a macOS update. EnerG judges from `CHLT` whether a limit took (`LimitCheck`): `CHLT` off means Calibration (macOS ignores every limit for now) and nothing is written. Another value is rewritten after 10 min, then with backoff up to every 160 min, and is reported as unsupported once a rewrite didn't help. The override is never reverted after a failed check, so macOS applies it by itself when it can; only a failed override write holds 80 instead. (Changed 2026-10-25: EnerG used to fall back to 80 for good, which a Calibration triggered.)
```

- [ ] **Step 3: Commit**

```bash
git add CONTEXT.md docs/adr/0001-sub-80-limits-via-smartcharging-override.md
git commit -m "docs: calibration term and the limit check in ADR 0001"
```

---

### Task 7: On-device check

- [ ] **Step 1:** Run `scripts/install.sh` (repo root). It may print the `kickstart` hint if `sudo -n` fails: ask the user to run it. Expected: EnerG reopens.
- [ ] **Step 2:** Ask the user to set 60%, plug in, and confirm the popover shows no warning, then `sudo Packages/EnerGKit/.build/out/Products/Debug/energ-smoke get-limit` after `swift build --package-path Packages/EnerGKit --product energ-smoke` shows `CHLT=60`. If macOS is still calibrating, expect the "Charge Limit paused by macOS" tile and `CHLT=off`.

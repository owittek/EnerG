# EnerG Polish Round 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the known issues left after EnerG v1 (spec: `docs/superpowers/specs/2026-10-20-energ-polish-design.md`).

**Architecture:**
- **Engine/Policy:** rule changes, each driven by `FakeHardware` tests.
- **`MacHardware`:** gains a plug-signal flag and live battery power from SMC.
- **App, energd and scripts:** small local fixes.
- **Docs:** the base spec, README and CONTEXT.md are updated last.

**Tech Stack:**
- Swift 6, Swift Testing.
- SwiftPM package `Packages/EnerGKit`.
- XcodeGen + xcodebuild for `EnerG.app` / `energd`.
- AppleSMC through `CPlatform`.

## Global Constraints

- **Platform:** macOS 27, Apple Silicon. `SWIFT_VERSION` is `"6.0"`.
- **Core tests:** `swift test --package-path Packages/EnerGKit`, run from the repo root. They must all pass at the end of every task.
- **App build check:** `xcodegen generate && xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug -derivedDataPath build -allowProvisioningUpdates build 2>&1 | grep -E "error:|warning: .*EnerG|BUILD (SUCCEEDED|FAILED)"`. Expected: `** BUILD SUCCEEDED **`.
- **Commits:** never add `Co-Authored-By` or any Claude/AI attribution to a commit message.
- **`.superpowers/`** is gitignored and never committed.
- **`sudo`:** the agent never runs `sudo`. On-device steps that need root are done by the user in their own terminal; the agent reads state unprivileged (`Packages/EnerGKit/.build/debug/energ-smoke status`, `ioreg`, `pmset -g batt`).
- **Style:** match the surrounding code. Keep the comment density and doc-comment style. Use the domain terms from `CONTEXT.md`: Charge Limit, Discharge, Discharge Target, Auto-Discharge, Top Up, Pause, Weak Adapter.
- **FakeHardware** lives in `Packages/EnerGKit/Tests/EnerGCoreTests/FakeHardware.swift`. `started(settings) { configure }` returns an Engine that has handled `.start`, with the writes cleared. Its default snapshot is 70 %, charging, plugged in, 20 W into the battery.

---

### Task 1: Unstick the native limit when the prior adapter state is unknown

Spec change 1, plus the test gap in change 19 (`startClearsAStaleDischarge`).

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (in `apply`, the `if next.adapterEnabled` branch)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/DischargeTests.swift`, `Packages/EnerGKit/Tests/EnerGCoreTests/EngineBasicsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: no API change.

- [ ] **Step 1: Write the failing tests.** Add to `EngineBasicsTests`:

```swift
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
```

In `DischargeTests`, replace `startClearsAStaleDischarge` with:

```swift
    @Test func startClearsAStaleDischarge() {
        let (engine, hw) = started()   // 70 %
        engine.handle(.command(.discharge(to: 50)))
        hw.writes.removeAll()
        let status = engine.handle(.start)
        #expect(hw.writes == [.adapter(true), .adapter(true), .limit(80), .led(.orange), .preventSleep(false)])
        #expect(status.dischargeTarget == nil)
    }
```

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `swift test --package-path Packages/EnerGKit --filter "AboveLimitReappliesNativeLimit|startClearsAStaleDischarge"`

Expected:
- Both `…AboveLimitReappliesNativeLimit` tests FAIL: the writes lack `.limit(nil)`.
- `startClearsAStaleDischarge` PASSES. It only strengthens the assertion.

- [ ] **Step 3: Implement.** In `Engine.apply`, change the re-apply condition and its comment:

```swift
            if next.adapterEnabled {
                enableFailed = !enableAdapter()
                // Adapter back on above the native limit after a cut, or after a start or wake where a cut
                // may still be in place: macOS stays on battery until the limit is disabled and set again.
                if !enableFailed, applied?.adapterEnabled != true,
                   let limit = next.chargeLimit, let snapshot, snapshot.percent > limit {
                    reapplyLimit = true
                }
```

- [ ] **Step 4: Run all core tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 5: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "fix: unstick the native limit after start and wake above the limit"
```

---

### Task 2: A failed native-limit re-apply doesn't latch

Spec change 2.

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (in `apply`, the `if reapplyLimit` block and the end of the function)
- Modify: `Packages/EnerGKit/Tests/EnerGCoreTests/FakeHardware.swift`
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/DischargeTests.swift`

**Interfaces:**
- Produces, test-only: `FakeHardware.failingLimits: Set<Int>`. Setting one of these non-nil limits throws `HardwareError.io(-2)`; `setChargeLimit(nil)` still succeeds.

- [ ] **Step 1: Extend FakeHardware.** Add the property next to `failing`:

```swift
    /// Non-nil limits whose write throws; disabling the limit still succeeds.
    var failingLimits: Set<Int> = []
```

and change `setChargeLimit`:

```swift
    func setChargeLimit(_ percent: Int?) throws {
        if failing.contains(.chargeLimit) { throw HardwareError.notPrivileged }
        if let percent, failingLimits.contains(percent) { throw HardwareError.io(-2) }
        writes.append(.limit(percent))
    }
```

- [ ] **Step 2: Write the failing tests.** Add to `DischargeTests`:

```swift
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
```

- [ ] **Step 3: Run the tests and confirm they fail.**

Run: `swift test --package-path Packages/EnerGKit --filter "failedReapplyLeavesLimitOffAndRetries|reapplyFailingAgainLatchesChargeLimit"`

Expected:
- `failedReapplyLeavesLimitOffAndRetries` FAILS: `.unavailable(.chargeLimit)` is present, and the tick writes nothing.
- The second test PASSES today, because the first failure already latches. It guards the new path.

- [ ] **Step 4: Implement.** In `Engine.apply`, replace the re-apply block:

```swift
        var limitLeftOff = false
        if reapplyLimit {
            write(.chargeLimit) {
                try hardware.setChargeLimit(nil)
                // Disabled but not set again: record it as off so the next evaluate sets it the normal way,
                // which latches unavailable only if that fails too.
                do { try hardware.setChargeLimit(next.chargeLimit) } catch { limitLeftOff = true }
            }
        } else if changed(\.chargeLimit, to: next) {
```

Then, after `applied = next`, add:

```swift
        if limitLeftOff { applied?.chargeLimit = nil }
```

Put it before the `if enableFailed` line.

- [ ] **Step 5: Run all core tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 6: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "fix: retry a failed native-limit re-apply instead of latching it"
```

---

### Task 3: Unplug ends a Discharge when the plug signal is physical

Spec change 3, which also covers handoff item 8.

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Model.swift` (`BatterySnapshot`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Policy.swift` (`Policy.update`)
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift` (`snapshot()`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/DischargeTests.swift`, `Packages/EnerGKit/Tests/EnerGCoreTests/EngineBasicsTests.swift`

**Interfaces:**
- Produces: `BatterySnapshot.plugSensed: Bool`. The init gains a trailing `plugSensed: Bool = true` parameter, so existing call sites compile unchanged. Task 7 also edits `MacHardware.snapshot()`.

- [ ] **Step 1: Add the field.** In `Model.swift`, add `plugSensed` to `BatterySnapshot`:

```swift
    /// Total system draw, if known.
    public var systemWatts: Double?
    /// `adapterConnected` was read from `AC-W`, so it stays true while EnerG cuts the adapter.
    /// False on the `ExternalConnected` fallback, where a cut itself reads as unplugged.
    public var plugSensed: Bool

    public init(percent: Int, isCharging: Bool, adapterConnected: Bool,
                adapterWatts: Int?, batteryWatts: Double, systemWatts: Double?, plugSensed: Bool = true) {
        self.percent = percent
        self.isCharging = isCharging
        self.adapterConnected = adapterConnected
        self.adapterWatts = adapterWatts
        self.batteryWatts = batteryWatts
        self.systemWatts = systemWatts
        self.plugSensed = plugSensed
    }
```

- [ ] **Step 2: Write the failing tests.** Add to `DischargeTests`:

```swift
    @Test func unplugEndsDischargeAndReplugRearmsAutoDischarge() {
        let (engine, hw) = dischargingAt92()
        hw.snap.adapterConnected = false
        hw.snap.batteryWatts = -15
        var status = engine.handle(.powerChanged)
        #expect(hw.writes == [.adapter(true), .limit(nil), .limit(80), .led(.system), .preventSleep(false)])
        #expect(status.dischargeTarget == nil)
        #expect(status.state == .onBattery)

        hw.writes.removeAll()
        hw.snap.adapterConnected = true
        status = engine.handle(.powerChanged)
        #expect(hw.writes == [.adapter(false), .led(.off), .preventSleep(true)])
        #expect(status.state == .discharging)
    }

    @Test func fallbackPlugSignalKeepsDischargeWhenCutHidesAdapter() {
        let (engine, hw) = started { $0.snap.plugSensed = false }
        hw.snap.percent = 92
        hw.snap.isCharging = false
        engine.handle(.powerChanged)
        hw.writes.removeAll()
        hw.snap.adapterConnected = false   // ExternalConnected reads No while CHIE cuts the adapter
        let status = engine.handle(.tick)
        #expect(hw.writes.isEmpty)
        #expect(status.dischargeTarget == 80)
    }
```

Add to `EngineBasicsTests`:

```swift
    @Test func dischargeRequestedJustAfterUnplugIsDropped() {
        let (engine, hw) = started()   // last snapshot: plugged in
        hw.snap.adapterConnected = false   // unplugged since, with no event yet
        hw.snap.isCharging = false
        let status = engine.handle(.command(.discharge(to: 50)))
        #expect(hw.writes == [.led(.system)])
        #expect(status.dischargeTarget == nil)
    }
```

In `DischargeTests.autoDischargeCutsAdapterUntilLimit`, delete the trailing comment `// CHIE=08 hides the adapter`. With `AC-W` that line now means an unplug.

- [ ] **Step 3: Run the tests and confirm they fail.**

Run: `swift test --package-path Packages/EnerGKit --filter "unplugEndsDischarge|fallbackPlugSignal|dischargeRequestedJustAfterUnplug"`

Expected:
- `unplugEndsDischargeAndReplugRearmsAutoDischarge` and `dischargeRequestedJustAfterUnplugIsDropped` FAIL: the Discharge keeps running.
- The fallback test PASSES.

- [ ] **Step 4: Implement the rule.** In `Policy.update`, insert this right after the paused early return, before the `if s.dischargeTarget == nil && !snapshot.adapterConnected` block:

```swift
        // Unplugged mid-Discharge. Only trusted from AC-W: on the fallback a cut itself reads as unplugged.
        if s.dischargeTarget != nil, snapshot.plugSensed, !snapshot.adapterConnected {
            s.dischargeTarget = nil
        }
```

Extend the doc comment's first line to: `/// Advances the session for a fresh snapshot: ends a Discharge, Top Up and suppression on unplug,`. Keep the rest of the comment as is.

- [ ] **Step 5: Set the flag in MacHardware.** In `MacHardware.snapshot()`:

```swift
        let plugged = physicallyPlugged()
        return BatterySnapshot(
            percent: percent,
            isCharging: p["IsCharging"] as? Bool ?? false,
            adapterConnected: plugged ?? (p["ExternalConnected"] as? Bool ?? false),
            adapterWatts: (adapter?["Watts"] as? NSNumber)?.intValue,
            batteryWatts: milliamps * millivolts / 1_000_000,
            systemWatts: (try? readFloat("PSTR")).map(Double.init),
            plugSensed: plugged != nil
        )
```

- [ ] **Step 6: Run all core tests, and build the package.**

Run: `swift test --package-path Packages/EnerGKit && swift build --package-path Packages/EnerGKit`
Expected: all tests pass and the build succeeds.

- [ ] **Step 7: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "fix: end a Discharge when every charger is unplugged"
```

---

### Task 4: Weak Adapter counts only ticks, and skips the first tick after a Discharge

Spec change 5, plus the interleaved-sample test from change 19.

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Policy.swift` (`Session`, `Policy.update`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (`handle`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/TopUpAndWarningsTests.swift`

**Interfaces:**
- Produces: `Session.dischargeJustEnded: Bool`. It is internal, and set by a `didSet` on `dischargeTarget`.

- [ ] **Step 1: Write the failing tests.** In `TopUpAndWarningsTests`, replace `weakAdapterCountsOnlyTicksAndPowerChanges` with:

```swift
    @Test func weakAdapterCountsOnlyTicks() {
        let (engine, hw) = started()
        hw.snap.batteryWatts = -5
        engine.handle(.tick)
        #expect(!engine.handle(.command(.getStatus)).warnings.contains(.weakAdapter))
        #expect(!engine.handle(.lid(closed: false)).warnings.contains(.weakAdapter))
        #expect(!engine.handle(.didWake).warnings.contains(.weakAdapter))
        #expect(!engine.handle(.powerChanged).warnings.contains(.weakAdapter))
        #expect(engine.handle(.tick).warnings.contains(.weakAdapter))
    }
```

Then add:

```swift
    @Test func noWeakAdapterBlipAfterCancelledDischarge() {
        let (engine, hw) = DischargeTests().dischargingAt92()
        hw.snap.batteryWatts = -5   // battery current still reflects the cut
        engine.handle(.command(.cancelDischarge))
        #expect(!engine.handle(.powerChanged).warnings.contains(.weakAdapter))
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))   // first tick after the Discharge: skipped
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))   // 1 sample
        #expect(engine.handle(.tick).warnings.contains(.weakAdapter))    // 2 samples: a real Weak Adapter
    }

    @Test func tickThatEndsDischargeDoesNotCountWeakSample() {
        let (engine, hw) = DischargeTests().dischargingAt92()
        hw.snap.percent = 80
        hw.snap.batteryWatts = -15
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))   // ends the Discharge: not counted
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))   // 1 sample
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
```

`dischargingAt92` is an instance method on the `DischargeTests` struct, so `DischargeTests().dischargingAt92()` works.

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `swift test --package-path Packages/EnerGKit --filter "weakAdapterCountsOnlyTicks|noWeakAdapterBlip|tickThatEndsDischarge|interleavedChargingSample"`

Expected:
- The first three FAIL: the warning appears early.
- `interleavedChargingSampleResetsWeakCount` PASSES.

- [ ] **Step 3: Implement the Session flag.** In `Policy.swift`, replace the `dischargeTarget` declaration in `Session`:

```swift
    /// Set while a Discharge runs.
    var dischargeTarget: Int? {
        didSet { if oldValue != nil, dischargeTarget == nil { dischargeJustEnded = true } }
    }
    /// A Discharge ended and no tick has run since. That tick's battery current still reflects the cut,
    /// so it doesn't count as a Weak Adapter sample.
    var dischargeJustEnded = false
```

- [ ] **Step 4: Implement the counting.** In `Policy.update`, replace the weak-sample block at the end:

```swift
        let weak = s.dischargeTarget == nil && snapshot.adapterConnected && snapshot.batteryWatts < 0
        if !weak {
            s.weakSamples = 0
        } else if countsWeakSample, !s.dischargeJustEnded {
            s.weakSamples += 1
        }
        if countsWeakSample { s.dischargeJustEnded = false }
```

Update the doc comment's `countsWeakSample` lines to:

```swift
    /// `countsWeakSample`: only ticks count towards a Weak Adapter, except the first tick after a Discharge
    /// ends; other events can only reset the count.
```

In `Engine.handle`, change the evaluate call to `evaluate(countsWeakSample: event == .tick)`.

- [ ] **Step 5: Run all core tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 6: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "fix: no false Weak Adapter warning right after a Discharge"
```

---

### Task 5: Pausing while the battery is unreadable clears running modes

Spec change 6.

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Policy.swift`
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (`evaluate`, the catch path)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/TopUpAndWarningsTests.swift`

**Interfaces:**
- Produces: `Policy.clearForPause(_ s: inout Session)`. It is internal.

- [ ] **Step 1: Write the failing test.** Add to `TopUpAndWarningsTests`:

```swift
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
```

- [ ] **Step 2: Run the test and confirm it fails.**

Run: `swift test --package-path Packages/EnerGKit --filter pauseWhileUnreadableEndsTopUp`
Expected: FAIL, because `toppingUp` is still true.

- [ ] **Step 3: Implement.** In `Policy`, add this above `update`:

```swift
    /// Pause drops every running mode.
    static func clearForPause(_ s: inout Session) {
        s.dischargeTarget = nil
        s.toppingUp = false
        s.autoSuppressed = false
        s.weakSamples = 0
    }
```

In `update`, replace the paused block's body with `clearForPause(&s)` followed by `return`. In `Engine.evaluate`'s catch path:

```swift
            if paused {
                Policy.clearForPause(&session)
                apply(.released, snapshot: nil)
            } else if var safe = applied {
```

- [ ] **Step 4: Run all core tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 5: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "fix: pausing while the battery is unreadable ends Top Up"
```

---

### Task 6: Fill the remaining Engine test gaps

Spec change 19: cancel suppression, and features latched unavailable.

**Files:**
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/DischargeTests.swift`, `Packages/EnerGKit/Tests/EnerGCoreTests/TopUpAndWarningsTests.swift`

- [ ] **Step 1: Add the tests.** Add to `DischargeTests`:

```swift
    @Test func cancelSuppressionClearsAtLimitWithoutUnplug() {
        let (engine, hw) = dischargingAt92()
        engine.handle(.command(.cancelDischarge))
        hw.snap.percent = 80
        engine.handle(.tick)
        hw.writes.removeAll()
        hw.snap.percent = 85
        let status = engine.handle(.tick)
        #expect(hw.writes == [.adapter(false), .led(.off), .preventSleep(true)])
        #expect(status.state == .discharging)
    }
```

Add to `TopUpAndWarningsTests`:

```swift
    @Test func latchedFeatureIsNotRetriedEvenOnWake() {
        let (engine, hw) = started { $0.failing = [.led] }
        hw.failing = []
        engine.handle(.command(.setLEDMode(.off)))
        engine.handle(.willSleep)
        engine.handle(.didWake)
        #expect(!hw.writes.contains { if case .led = $0 { true } else { false } })
        #expect(engine.handle(.tick).warnings.contains(.unavailable(.led)))
    }
```

- [ ] **Step 2: Run all core tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass. These pin down existing behaviour.

- [ ] **Step 3: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "test: cover cancel suppression clearing and latched features"
```

---

### Task 7: Lenient Settings decoding, and test temp-dir cleanup

Spec change 14, plus the `SettingsStoreTests` part of change 19.

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Model.swift` (`Settings`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/SettingsStoreTests.swift`

- [ ] **Step 1: Rewrite the test suite with cleanup and add new tests.** Replace the whole file:

```swift
import Foundation
import Testing
@testable import EnerGCore

/// A class so `deinit` can remove each test's temp directory.
final class SettingsStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "energ-tests-\(UUID().uuidString)")
    var url: URL { root.appending(path: "nested/settings.json") }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func missingFileLoadsDefaults() {
        #expect(SettingsStore(url: url).load() == Settings())
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = SettingsStore(url: url)
        let settings = Settings(chargeLimit: 95, autoDischarge: false, ledMode: .blink, paused: true)
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func disallowedChargeLimitLoadsDefaultLimit() throws {
        let store = SettingsStore(url: url)
        try store.save(Settings(chargeLimit: 87, autoDischarge: false, ledMode: .off, paused: true))
        #expect(store.load() == Settings(chargeLimit: 80, autoDischarge: false, ledMode: .off, paused: true))
    }

    @Test func corruptFileLoadsDefaults() throws {
        try write("not json")
        #expect(SettingsStore(url: url).load() == Settings())
    }

    @Test func missingFieldDefaultsOnlyThatField() throws {
        try write(#"{"chargeLimit":90,"autoDischarge":false,"paused":true}"#)
        #expect(SettingsStore(url: url).load() == Settings(chargeLimit: 90, autoDischarge: false, ledMode: .auto, paused: true))
    }

    @Test func invalidFieldDefaultsOnlyThatField() throws {
        try write(#"{"chargeLimit":90,"autoDischarge":false,"ledMode":"rainbow","paused":true}"#)
        #expect(SettingsStore(url: url).load() == Settings(chargeLimit: 90, autoDischarge: false, ledMode: .auto, paused: true))
    }
}
```

If Swift 6 rejects a non-`Sendable` class suite, mark it `@unchecked Sendable`: each test runs on a fresh instance.

- [ ] **Step 2: Run the tests and confirm they fail.**

Run: `swift test --package-path Packages/EnerGKit --filter SettingsStoreTests`
Expected: `missingFieldDefaultsOnlyThatField` and `invalidFieldDefaultsOnlyThatField` FAIL, because the whole Settings resets to defaults. The others pass.

- [ ] **Step 3: Implement.** In `Settings`, after the memberwise `init`, add:

```swift
    /// Each field falls back to its default when missing or invalid, so adding a field later keeps the others.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        chargeLimit = (try? c.decodeIfPresent(Int.self, forKey: .chargeLimit)) ?? d.chargeLimit
        autoDischarge = (try? c.decodeIfPresent(Bool.self, forKey: .autoDischarge)) ?? d.autoDischarge
        ledMode = (try? c.decodeIfPresent(LEDMode.self, forKey: .ledMode)) ?? d.ledMode
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? d.paused
    }
```

`CodingKeys` and `encode(to:)` stay synthesized.

- [ ] **Step 4: Run all core tests, then confirm no temp dirs are left behind.**

Run: `swift test --package-path Packages/EnerGKit && ls "$(getconf DARWIN_USER_TEMP_DIR)" | grep -c energ-tests`

Expected: all tests pass, and the count is `0`. Directories left by earlier runs may make it non-zero. If so, delete them once with `rm -rf "$(getconf DARWIN_USER_TEMP_DIR)"/energ-tests-*` and re-run.

- [ ] **Step 5: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "fix: decode Settings field by field; clean up test temp dirs"
```

---

### Task 8: Live battery power from SMC, and a checked sleep assertion

Spec changes 7 and 16. A probe on 2026-10-20 (Mac17,8) gave these facts:
- `B0AC` is si16, little-endian, battery current in mA, negative while discharging.
- `B0AV` is ui16, little-endian, battery voltage in mV.
- Both read unprivileged and update live. The `AppleSmartBattery` registry refreshes only about every 60 s.
- Measured while cut: B0AC × B0AV gave −13.4 / −10.0 / −10.7 / −8.9 W, against `PSTR` 16.9 / 11.0 / 9.9 / 9.7 W.

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift`

**Interfaces:**
- Consumes: Task 3's `snapshot()` shape, including `plugSensed: plugged != nil`.
- Produces: no API change. `batteryWatts` becomes live.

- [ ] **Step 1: Add a sized SMC read helper, and route the existing reads through it.** Replace `physicallyPlugged()` and `readFloat(_:)` with:

```swift
    /// `AC-W` (si8): > 0 while a charger is physically plugged in, also while CHIE cuts it
    /// (ExternalConnected then reads No); -1 when unplugged. nil if the key is missing or unreadable.
    private func physicallyPlugged() -> Bool? {
        guard let bytes = try? read("AC-W", size: 1) else { return nil }
        return Int8(bitPattern: bytes[0]) > 0
    }

    /// Battery power from `B0AC` (si16 mA, negative while discharging) × `B0AV` (ui16 mV). Live, unlike the
    /// registry, which refreshes about once a minute. nil if either key can't be read.
    private func liveBatteryWatts() -> Double? {
        guard let current = try? read("B0AC", size: 2), let voltage = try? read("B0AV", size: 2) else { return nil }
        let milliamps = Int16(bitPattern: UInt16(current[0]) | UInt16(current[1]) << 8)
        let millivolts = UInt16(voltage[0]) | UInt16(voltage[1]) << 8
        return Double(milliamps) * Double(millivolts) / 1_000_000
    }

    private func readFloat(_ key: String) throws -> Float {
        let b = try read(key, size: 4)
        return Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }

    /// Reads a key that must be exactly `size` bytes (little-endian on Apple Silicon).
    private func read(_ key: String, size expected: UInt32) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var result: UInt8 = 0
        let kr = smc_read(smc, key, &buf, &size, &result)
        try checkSMC(kr, result, key)
        guard size == expected else { throw HardwareError.keyMissing(key) }
        return Array(buf.prefix(Int(size)))
    }
```

- [ ] **Step 2: Use it in `snapshot()`.** Change the `batteryWatts:` argument to:

```swift
            batteryWatts: liveBatteryWatts() ?? milliamps * millivolts / 1_000_000,
```

In the class doc comment, change the first line to: `/// The real Mac: AppleSMC (CHIE adapter cut, ACLC LED, PSTR system power, AC-W plug presence, B0AC/B0AV battery power), PowerUI native`.

- [ ] **Step 3: Check the sleep assertion result.** Add `import OSLog` at the top, and add this as a stored property under `sleepAssertion`:

```swift
    private let log = Logger(subsystem: "app.energ", category: "hardware")
```

Then change `setPreventSleep`'s `on` branch:

```swift
        if on, sleepAssertion == 0 {
            let rc = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "EnerG Discharge" as CFString, &sleepAssertion)
            // Without it the Mac may idle-sleep, and willSleep then ends the Discharge safely.
            if rc != kIOReturnSuccess {
                sleepAssertion = 0
                log.error("sleep assertion failed: \(rc, privacy: .public)")
            }
        } else if !on, sleepAssertion != 0 {
```

- [ ] **Step 4: Build the package, run the tests, and check against the hardware.** These are unprivileged commands.

```bash
swift build --package-path Packages/EnerGKit && swift test --package-path Packages/EnerGKit
for i in 1 2 3; do Packages/EnerGKit/.build/debug/energ-smoke status; pmset -g batt | head -1; sleep 2; done
```

Expected:
- The build and tests pass.
- On AC at the limit, `batteryWatts` is near 0.
- While charging it is positive, and on battery it is negative, roughly matching `-systemWatts`.
- It changes from sample to sample. It is no longer constant for a minute.

- [ ] **Step 5: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "fix: live battery power from SMC; log a failed sleep assertion"
```

---

### Task 9: energ-smoke error reporting and limit validation

Spec change 18.

**Files:**
- Modify: `Packages/EnerGKit/Sources/energ-smoke/main.swift`

- [ ] **Step 1: Implement.** Replace the `get-limit` and `limit` cases:

```swift
    case ("get-limit", _):
        var limit: UInt8 = 0
        var enabled = false
        let rc = powerui_get_limit(&limit, &enabled)
        guard rc == 0 else { throw rc == -1 ? HardwareError.frameworkUnavailable : HardwareError.io(rc) }
        print(enabled ? "\(limit)" : "off")
```

```swift
    case ("limit", _):
        guard let limit = Int(argument), (0...100).contains(limit) else { print(usage); exit(2) }
        try hw.setChargeLimit(limit)
```

- [ ] **Step 2: Build and check.** These are unprivileged.

```bash
swift build --package-path Packages/EnerGKit --product energ-smoke
Packages/EnerGKit/.build/debug/energ-smoke limit 300; echo "exit $?"
Packages/EnerGKit/.build/debug/energ-smoke get-limit; echo "exit $?"
```

Expected:
- `limit 300` prints the usage text and `exit 2`. It doesn't trap.
- `get-limit` prints a limit or `off` with `exit 0`, or a specific `error: io(…)` / `frameworkUnavailable`.

- [ ] **Step 3: Commit.**

```bash
git add Packages/EnerGKit
git commit -m "fix: energ-smoke reports real PowerUI errors and validates limits"
```

---

### Task 10: energd decodes XPC requests itself

Spec change 15.

**Files:**
- Modify: `energd/main.swift` (`makeListener()`)

**Interfaces:**
- Consumes the XPC overlay, as of the macOS 27 SDK:
  - `IncomingSessionRequest.accept<Handler: XPCPeerHandler>(_ inactiveSessionHandler: (XPCSession) -> Handler)` where `Handler.Input == XPCReceivedMessage` and `Handler.Output == any Encodable`;
  - `XPCReceivedMessage.decode(as:) throws`;
  - `XPCSession.cancel(reason:)`.

- [ ] **Step 1: Implement.** Above `makeListener()`, add:

```swift
/// Decodes each request itself, so a malformed message is logged and its session cancelled
/// (the client's reply handler then gets an error) instead of being left to the typed overlay.
struct RequestHandler: XPCPeerHandler {
    let session: XPCSession

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        do {
            return host.handle(.command(try message.decode(as: Request.self)))
        } catch {
            log.error("undecodable request: \(String(describing: error), privacy: .public)")
            session.cancel(reason: "undecodable request")
            return nil
        }
    }
}
```

In `makeListener()`, replace the trailing closure body with:

```swift
                               requirement: .isFromSameTeam(andMatchesSigningIdentifier: "app.energ.EnerG")) { request in
            request.accept { session in RequestHandler(session: session) }
        }
```

Swift 6 may reject the struct, because `XPCPeerHandler` is `Sendable` and `XPCSession` may not be. In that case, declare it `struct RequestHandler: XPCPeerHandler, @unchecked Sendable`, and add `// XPCSession is thread-safe; it is only cancelled here.` above it.

- [ ] **Step 2: Build the app.** Run the app build check from Global Constraints.
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit.**

```bash
git add energd/main.swift
git commit -m "fix: energd decodes XPC requests itself and cancels on a bad message"
```

---

### Task 11: App fixes, including honest "Uninstall Anyway"

Spec changes 4 (app text) and 8–13.

**Files:**
- Modify: `EnerG/AppModel.swift`, `EnerG/DaemonClient.swift`, `EnerG/PopoverView.swift`

- [ ] **Step 1: Honest Uninstall Anyway text (change 4).** In `AppModel.uninstallHelper`, replace the doc comment and the error text:

```swift
    /// `skipRelease`: "Uninstall Anyway" after a failed release. If energd is still running, its SIGTERM stop
    /// turns the adapter on and hands the LED back; if not, they stay as last set. The native Charge Limit may stay on.
```

```swift
                actionError = "Couldn't release charging control, so the helper wasn't uninstalled: "
                    + "\(error.localizedDescription). Uninstall Anyway removes the helper without handing "
                    + "charging back first. If the helper is still running, it restores the adapter and LED "
                    + "as it stops; if not, they may stay as last set. The native Charge Limit may stay on."
```

- [ ] **Step 2: Report the launch-at-login default failure (change 11).** In `AppModel.init`:

```swift
        if !UserDefaults.standard.bool(forKey: key) {
            do { try HelperInstaller.setLaunchAtLogin(true) } catch {
                actionError = "Couldn't turn on Launch at Login: \(error.localizedDescription)"
            }
            UserDefaults.standard.set(true, forKey: key)
            launchAtLogin = HelperInstaller.launchAtLogin
        }
```

- [ ] **Step 3: Move the AlDente scan off the main actor, every 10 s and on open (change 13).** In `AppModel`:
  - Add `private var lastAlDenteScan: ContinuousClock.Instant?` next to `polling`.
  - In `startPolling()`, set `lastAlDenteScan = nil` before creating the task, so opening the popover scans at once.
  - Mark `isProcessRunning` as `nonisolated private static func`.
  - In `refresh()`, replace the `alDenteRunning = …` statement with:

```swift
        let now = ContinuousClock.now
        if lastAlDenteScan.map({ $0.duration(to: now) >= .seconds(10) }) ?? true {
            lastAlDenteScan = now
            // ~700 proc_pidpath calls: keep them off the main actor.
            let helperRunning = await Task.detached {
                Self.isProcessRunning(executable: "com.apphousekitchen.aldente-pro.helper")
            }.value
            alDenteRunning = helperRunning || NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == "com.apphousekitchen.aldente-pro" }
        }
```

- [ ] **Step 4: Cancel the session if send throws (change 12).** In `DaemonClient.send`, replace the `do` body:

```swift
            do {
                let session = try XPCSession(machService: DaemonID.machService, options: .privileged,
                                             requirement: .isFromSameTeam())
                do {
                    try session.send(request) { (result: Result<Status, any Error>) in
                        session.cancel(reason: "done")
                        continuation.resume(with: result)
                    }
                } catch {
                    session.cancel(reason: "send failed")
                    throw error
                }
            } catch {
                continuation.resume(throwing: error)
            }
```

- [ ] **Step 5: Allow uninstall while approval is pending (change 8).** In `PopoverView.Footer`:

```swift
            Button("Uninstall Helper") { Task { await model.uninstallHelper() } }
                .disabled(model.helper != .enabled && model.helper != .requiresApproval)
```

`uninstallHelper()` already sends `release` only when the status is `.enabled`.

- [ ] **Step 6: Skip an unchanged setLimit (change 9).** In `BatteryTile`'s `onEditingChanged`:

```swift
                   onEditingChanged: { editing in
                       guard !editing, let draft = draftLimit else { return }
                       guard Int(draft) != status.settings.chargeLimit else {
                           draftLimit = nil
                           return
                       }
                       Task {
                           await model.perform(.setLimit(Int(draft)))
                           draftLimit = nil
                       }
                   })
```

- [ ] **Step 7: Toggle actions read the current status (change 10).** In `ControlGrid`, change the action closures so they read `model.status` when tapped. Labels, `isOn` and `disabled` keep using `status`.

```swift
                ToggleTile(symbol: "battery.25percent", title: "Discharge",
                           subtitle: status.dischargeTarget.map { "To \($0)% · click stop" } ?? "Run on battery",
                           isOn: discharging, disabled: dischargeDisabled) {
                    guard let current = model.status else { return }
                    if current.dischargeTarget != nil {
                        Task { await model.perform(.cancelDischarge) }
                    } else {
                        model.dischargeTarget = current.defaultDischargeTarget
                        choosingTarget = true
                    }
                }
```

```swift
                    guard let current = model.status else { return }
                    Task { await model.perform(.setAutoDischarge(!current.settings.autoDischarge)) }
```

```swift
                    guard let current = model.status else { return }
                    Task { await model.perform(current.toppingUp ? .cancelTopUp : .topUp) }
```

```swift
                    guard let current = model.status else { return }
                    Task { await model.perform(.setPaused(current.state != .paused)) }
```

```swift
                    guard let current = model.status else { return }
                    Task { await model.perform(.setLEDMode(current.settings.ledMode.next)) }
```

These go into the Auto-Discharge, Top Up, Pause and MagSafe LED tiles respectively. Leave Launch at Login as is: it already reads `model`.

- [ ] **Step 8: Build the app.** Run the app build check from Global Constraints.
Expected: `** BUILD SUCCEEDED **`, with no new warnings in EnerG sources.

- [ ] **Step 9: Commit.**

```bash
git add EnerG
git commit -m "fix: app nits — honest Uninstall Anyway, off-main AlDente scan, fresh toggle state"
```

---

### Task 12: install.sh log, README, base spec and glossary

Spec changes 4 (README and base spec), 17 and 20, plus the new platform facts.

**Files:**
- Modify: `scripts/install.sh`, `README.md`, `docs/superpowers/specs/2026-10-20-energ-design.md`, `CONTEXT.md`

- [ ] **Step 1: install.sh (change 17).** Replace the `xcodebuild … | tail -3` statement with:

```bash
mkdir -p build
LOG=build/xcodebuild.log
if ! xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20 || true
  echo "xcodebuild failed; full log: $LOG"
  exit 1
fi
tail -3 "$LOG"
```

- [ ] **Step 2: Verify install.sh fails loudly.** Temporarily break the build. One way: insert `let x: Int = ""` into `EnerG/EnerGApp.swift`.
  - Run: `scripts/install.sh; echo "exit $?"`.
  - Expected: the `error:` line naming `EnerGApp.swift`, `xcodebuild failed; full log: build/xcodebuild.log`, and `exit 1`.
  - Then revert the change with `git checkout EnerG/EnerGApp.swift`.
  - Don't run the successful install here; Task 13 does that.

- [ ] **Step 3: README.**
  - In **Build**, after the Team ID paragraph, add: "Contributors: `project.yml` commits the author's team (`XG5GU82KF7`). Replace it with your own team ID; signing fails with someone else's."
  - In **How it works**, after the `CHIE` bullet, add: "It cuts USB-C input as well as MagSafe, also with both attached. The SMC key `AC-W` reports whether any charger is physically plugged in, even while it is cut."
  - Add a bullet: "Battery power is read live from the SMC keys `B0AC` × `B0AV`; the battery registry refreshes only about once a minute."
  - In **Uninstall**, replace the "Uninstall Anyway" bullet with: "If the helper can't be reached, the notice offers **Uninstall Anyway**. It removes the helper without handing charging back first. If the helper is still running, it restores the adapter and LED as it stops; if not, they may stay as last set. The native macOS Charge Limit may stay at its last value."

- [ ] **Step 4: Base spec `docs/superpowers/specs/2026-10-20-energ-design.md`.**
  - **Verified platform facts:** add a bullet list from the polish spec's "New platform facts", with these changes:
    - The registry cadence is "about every 60 s, on AC and on battery". The 2026-10-20 probe saw `UpdateTime` lag 50 s on AC too.
    - Add a fact for `B0AC` (si16 mA) and `B0AV` (ui16 mV), little-endian, unprivileged and live.
  - **Native-limit unstick:** change "when the Engine turns the adapter back on after cutting it" to "when the Engine turns the adapter on and its prior state is cut or unknown (start, wake)".
  - **When a Discharge ends:** add "when every charger is unplugged (only when plug presence comes from `AC-W`)".
  - **Weak Adapter:** change "2 consecutive snapshots" to "2 consecutive ticks (30 s apart); the first tick after a Discharge ends doesn't count".
  - **Error handling, Uninstall:** replace "energd's SIGTERM stop restores the adapter and LED; the native limit may stay on" with "If energd is still running, its SIGTERM stop restores the adapter and LED; if not, they may stay as last set. The native limit may stay on."
  - **Hardware port row:** add `plugSensed` (adapterConnected came from `AC-W`) to the snapshot fields, and note that `batteryWatts` comes from `B0AC`×`B0AV` with a registry fallback.

- [ ] **Step 5: CONTEXT.md.** In **Relationships**, change the first bullet to: "A **Discharge** ends at its **Discharge Target**, on sleep, on lid close, or when the charger is unplugged."

- [ ] **Step 6: Commit.**

```bash
git add scripts/install.sh README.md docs/superpowers/specs/2026-10-20-energ-design.md CONTEXT.md
git commit -m "docs: polish round facts, honest uninstall, contributor team; install.sh keeps the build log"
```

---

### Task 13: Install and verify on device (with the user)

Spec "Verification". The user runs every `sudo` command; the agent samples state unprivileged and reports.

- [ ] **Step 1: Run the tests and install.**
  - Run `swift test --package-path Packages/EnerGKit`. Expected: all pass.
  - Run `scripts/install.sh`. Expected: the build tail ends in `** BUILD SUCCEEDED **`, and EnerG opens.
  - Ask the user to run `sudo launchctl kickstart -k system/app.energ.energd`.

- [ ] **Step 2: Check item 1, unstick after a crash.**
  - Setup: EnerG is not paused, Auto-Discharge is on, and the battery is above the limit, so a Discharge is running. If the battery is at or below the limit, the user starts a manual Discharge instead.
  - The user runs `sudo pkill -9 -x energd`.
  - The agent runs `pmset -g batt | head -1` every 2 s for 20 s.
  - Expected: launchd relaunches energd. Above the limit with Auto-Discharge, the Discharge resumes. Otherwise "AC Power" returns within seconds, not after 26 s or more.
  - Repeat with Auto-Discharge off. A manual Discharge is not persisted, so after the relaunch the result must be "AC Power" within seconds.

- [ ] **Step 3: Check item 3, unplug ends a Discharge.**
  - The user starts a Discharge, then unplugs every charger.
  - The agent checks `energ-smoke status`: `adapterConnected: false`. The popover state is "On battery", no longer Discharging.
  - The user replugs. With Auto-Discharge on and the battery above the limit, it shows Discharging again.

- [ ] **Step 4: Check item 6, no Weak Adapter blip.**
  - The user cancels a Discharge above the limit.
  - With the popover open for 60 s, no Weak Adapter notice appears.

- [ ] **Step 5: Check item 10, live power.**
  - During a Discharge, the popover's battery flow shows a negative value within about 2 s of the cut, and it moves.
  - On AC at the limit it shows about 0 W.

- [ ] **Step 6: Report.** Give the user a pass/fail line per check. Record any failure as a new issue for systematic debugging; don't patch it inline.

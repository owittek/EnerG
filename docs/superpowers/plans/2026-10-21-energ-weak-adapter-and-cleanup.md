# Weak Adapter and Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Weak Adapter into a "· light work" note on the adapter's rating, and fix the known issues left by the limits redesign.

**Architecture:**
- The Weak Adapter warning and its Policy rule are removed. The popover copy (`stateLabel`, `ChargeState.label`, a new `adapterLabel`) moves into EnerGCore so it can be unit-tested.
- Three Engine fixes:
  - A pulse that leaves the adapter cut (`HardwareError.adapterCut`) is retried once on the next event.
  - A sub-80 limit is re-set on plug-in.
  - Limit Drain requires `!isCharging`.
- NativeLimit fixes: it reads `CHLT` before the re-apply disable, and waits one poll before the first read after a re-apply.
- MacHardware re-reads `CHIE` before healing.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI app (XcodeGen), macOS 27.

Spec: `docs/superpowers/specs/2026-10-21-energ-weak-adapter-and-cleanup-design.md`. Glossary: `CONTEXT.md`.

## Global Constraints

- Run the tests with `swift test --package-path Packages/EnerGKit`. Every task ends with all tests passing.
- Build the app with: `xcodegen generate && xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug -derivedDataPath build -allowProvisioningUpdates build -quiet` (from the repo root). Run it in any task that touches `EnerG/`, `energd/` or a public EnerGCore API.
- Weak Adapter threshold: an adapter rated **below 50 W**. 50 W itself is not weak.
- Copy, exact: `"N W · light work"`, `"N W · idle"`, `"N W"`, `"Unplugged"`, `"Connected"`. The separator is ` · ` (U+00B7 with a space on each side).
- Commit messages follow the repo style (`fix:`, `feat:`, `refactor:`, `test:`, `docs:`), lower case. **Never** add `Co-Authored-By` or any Claude/AI attribution.
- Never commit `.superpowers/`. Work in a worktree under `.claude/worktrees/`.
- Never run `sudo`. When a step needs root, ask the user to run the command in their own terminal.
- Comments match the surrounding code: short doc comments that state the contract, wrapped at ~120 columns.

---

### Task 1: Remove the Weak Adapter warning and rule

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Model.swift` (`Warning`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Policy.swift` (`Session`, `clearForPause`, `update`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (`handle`, `evaluate`, `status`)
- Modify: `EnerG/PopoverView.swift` (`Warning.label`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/LimitTests.swift`, `TopUpAndWarningsTests.swift`, `EngineBasicsTests.swift`, `ProtocolTests.swift`

**Interfaces:**
- Produces:
  - `Policy.update(settings: Settings, snapshot: BatterySnapshot, session: inout Session)`.
  - `Engine.evaluate()` takes no parameter.
  - `Warning` has no `weakAdapter` case.

This is a removal, so there is no failing test first. The compiler finds every remaining use.

- [ ] **Step 1: Remove the case from `Warning`** in `Model.swift`. Delete the line `    case weakAdapter`, leaving:

```swift
public enum Warning: Codable, Hashable, Sendable {
    /// A Charge Limit below 80 didn't take, so 80 is in effect.
    case lowLimitUnsupported
    case unavailable(Feature)
    case batteryUnreadable
}
```

- [ ] **Step 2: Simplify Policy.** In `Policy.swift`, remove `var weakSamples = 0` from `Session`, then replace `clearForPause` and `update` with:

```swift
    /// Pause drops every running mode.
    static func clearForPause(_ s: inout Session) {
        s.toppingUp = false
    }

    /// Advances the session for a fresh snapshot: ends a Top Up on unplug.
    static func update(settings: Settings, snapshot: BatterySnapshot, session s: inout Session) {
        if isPaused(settings, s) {
            clearForPause(&s)
            return
        }
        if !snapshot.adapterConnected { s.toppingUp = false }
    }
```

- [ ] **Step 3: Update the Engine.** In `Engine.swift`:
  - In `handle`, replace `evaluate(countsWeakSample: event == .tick)` with `evaluate()`.
  - Change `private func evaluate(countsWeakSample: Bool) {` to `private func evaluate() {`.
  - Change the update call to `Policy.update(settings: settings, snapshot: current, session: &session)`.
  - In `status()`, delete `if session.weakSamples >= 2 { warnings.append(.weakAdapter) }`.

- [ ] **Step 4: Update the app.** In `EnerG/PopoverView.swift`, delete the line `case .weakAdapter: "Weak Adapter: the battery is draining while plugged in."` from `extension Warning`.

- [ ] **Step 5: Update the tests.**
  - `LimitTests.swift`: replace `aboveTheLimitIsLimitDrainNotWeakAdapter` with the test below. Delete `weakAdapterAtTheLimitCounts` and `weakAdapterCountsAtAnyPercentWithoutALimit`.

```swift
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
```

  - `TopUpAndWarningsTests.swift`: delete `weakAdapterNeedsTwoConsecutiveDrainingSamples`, `weakAdapterCountsOnlyTicks` and `interleavedChargingSampleResetsWeakCount`.
  - `EngineBasicsTests.swift`: in `unpluggedHandsLEDToSystem`, delete the line `#expect(!status.warnings.contains(.weakAdapter))`.
  - `ProtocolTests.swift`: in `statusRoundTrips`, change the warnings to `[.lowLimitUnsupported, .unavailable(.led), .batteryUnreadable]`.

- [ ] **Step 6: Check that nothing is left.**

Run: `grep -rn "weakAdapter\|weakSamples\|countsWeakSample\|Weak Adapter" Packages EnerG energd`
Expected: no output.

- [ ] **Step 7: Run the tests and build the app.**

Run: `swift test --package-path Packages/EnerGKit`, then the app build from Global Constraints.
Expected: all tests pass and the build succeeds.

- [ ] **Step 8: Commit**

```bash
git add -A Packages EnerG
git commit -m "refactor: remove the Weak Adapter warning and its Policy rule"
```

---

### Task 2: Popover labels in EnerGCore, with "· light work"

**Files:**
- Create: `Packages/EnerGKit/Sources/EnerGCore/Labels.swift`
- Modify: `EnerG/PopoverView.swift`:
  - `PowerFlowTile`: around line 249, `node("powerplug.fill", adapterText(snapshot))`, plus the `adapterText` func at ~275–279.
  - The second `extension Status` (`stateLabel`) at ~312–327.
  - `extension ChargeState` (`label`) at ~329–341.
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/LabelTests.swift`

**Interfaces:**
- Consumes: `Status`, `ChargeState`, `BatterySnapshot` (EnerGCore, all public).
- Produces:
  - `public extension ChargeState { var label: String }`.
  - `public extension Status`:
    - `static let weakAdapterBelowWatts = 50`.
    - `var stateLabel: String`.
    - `var adapterLabel: String`.

- [ ] **Step 1: Write the failing tests.** Create `LabelTests.swift`:

```swift
import Testing
@testable import EnerGCore

struct LabelTests {
    private func status(_ state: ChargeState, percent: Int = 80, effectiveLimit: Int? = 80,
                        adapterConnected: Bool = true, adapterWatts: Int? = 96) -> Status {
        Status(state: state, settings: Settings(),
               snapshot: BatterySnapshot(percent: percent, isCharging: state == .charging,
                                         adapterConnected: adapterConnected, adapterWatts: adapterWatts,
                                         batteryWatts: 0, systemWatts: 10),
               effectiveLimit: effectiveLimit, toppingUp: false, warnings: [])
    }

    // A Weak Adapter's note wins over "idle": the rating is what the user needs to know.
    @Test func adapterLabel() {
        #expect(status(.onBattery, adapterConnected: false).adapterLabel == "Unplugged")
        #expect(status(.atLimit, adapterWatts: nil).adapterLabel == "Connected")
        #expect(status(.atLimit, adapterWatts: 96).adapterLabel == "96 W")
        #expect(status(.limitDrain, percent: 85, adapterWatts: 96).adapterLabel == "96 W · idle")
        #expect(status(.atLimit, adapterWatts: 50).adapterLabel == "50 W")
        #expect(status(.atLimit, adapterWatts: 45).adapterLabel == "45 W · light work")
        #expect(status(.limitDrain, percent: 85, adapterWatts: 30).adapterLabel == "30 W · light work")
    }

    @Test func adapterLabelWithoutASnapshot() {
        let unreadable = Status(state: .unknown, settings: Settings(), snapshot: nil,
                                effectiveLimit: nil, toppingUp: false, warnings: [.batteryUnreadable])
        #expect(unreadable.adapterLabel == "—")
    }

    @Test func stateLabel() {
        #expect(status(.limitDrain, percent: 85, effectiveLimit: 60).stateLabel == "Draining to 60%")
        #expect(status(.limitDrain, percent: 85, effectiveLimit: nil).stateLabel == "Draining to limit")
        #expect(status(.atLimit, percent: 80).stateLabel == "Holding at 80%")
        #expect(status(.atLimit, percent: 77).stateLabel == "Not charging · resumes below 75%")
        #expect(status(.atLimit, percent: 74).stateLabel == "Not charging")
        #expect(status(.atLimit, effectiveLimit: nil).stateLabel == "Not charging")
        #expect(status(.charging, percent: 70).stateLabel == "Charging")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail.**

Run: `swift test --package-path Packages/EnerGKit --filter LabelTests`
Expected: a compile failure. `adapterLabel` and `stateLabel` aren't members of `Status`, and `label` isn't a member of `ChargeState`.

- [ ] **Step 3: Implement.** Create `Labels.swift`. The `stateLabel` and `ChargeState.label` bodies are moved verbatim from the app, now `public`:

```swift
/// Popover copy derived from a Status. Kept here, not in the app, so it is unit-tested.
extension ChargeState {
    public var label: String {
        switch self {
        case .charging: "Charging"
        case .atLimit: "Holding at limit"
        case .limitDrain: "Draining to limit"
        case .toppingUp: "Topping up to 100%"
        case .paused: "Paused"
        case .onBattery: "On battery"
        case .unknown: "Battery unreadable"
        }
    }
}

extension Status {
    /// Below this rating an adapter is a Weak Adapter: enough for light work, not for sustained load.
    public static let weakAdapterBelowWatts = 50

    /// The state line under the battery %. "At limit" covers the firmware band below the limit too,
    /// where macOS doesn't charge until the battery drops 5 points under it.
    public var stateLabel: String {
        switch state {
        case .limitDrain:
            return effectiveLimit.map { "Draining to \($0)%" } ?? state.label
        case .atLimit:
            guard let limit = effectiveLimit, let percent = snapshot?.percent else { return "Not charging" }
            if percent >= limit { return "Holding at \(limit)%" }
            return percent >= limit - 5 ? "Not charging · resumes below \(limit - 5)%" : "Not charging"
        default:
            return state.label
        }
    }

    /// The text under the adapter icon: its rating, plus "light work" for a Weak Adapter (also during a Limit
    /// Drain) or "idle" during a Limit Drain, when macOS runs the Mac from the battery.
    public var adapterLabel: String {
        guard let snapshot else { return "—" }
        guard snapshot.adapterConnected else { return "Unplugged" }
        guard let watts = snapshot.adapterWatts else { return "Connected" }
        if watts < Self.weakAdapterBelowWatts { return "\(watts) W · light work" }
        return state == .limitDrain ? "\(watts) W · idle" : "\(watts) W"
    }
}
```

- [ ] **Step 4: Use it in the app.** In `EnerG/PopoverView.swift`:
  - Change `node("powerplug.fill", adapterText(snapshot))` to `node("powerplug.fill", status.adapterLabel)`.
  - Delete the whole `private func adapterText(_ snapshot: BatterySnapshot) -> String { … }`.
  - Delete the second `extension Status { … var stateLabel … }` block and the `extension ChargeState { var label … }` block. Only the `extension Status { func isUnavailable … }` block stays, so the two `Status` extensions are effectively merged.

- [ ] **Step 5: Run the tests and build the app.**

Run: `swift test --package-path Packages/EnerGKit`, then the app build.
Expected: all tests pass and the build succeeds.

- [ ] **Step 6: Commit**

```bash
git add -A Packages EnerG
git commit -m "feat: adapter row notes a Weak Adapter as light work; popover labels move to EnerGCore"
```

---

### Task 3: Limit Drain requires the battery not to be charging

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (`state()`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/LimitTests.swift`

**Interfaces:** none new.

- [ ] **Step 1: Write the failing test.** Add to `LimitTests`:

```swift
    // Right after the limit is lowered macOS still reports charging for a moment; that isn't a Limit Drain yet.
    @Test func aboveTheLimitWhileStillChargingIsCharging() {
        let (engine, hw) = started()
        hw.snap.percent = 83
        hw.snap.isCharging = true
        #expect(engine.handle(.tick).state == .charging)
    }
```

- [ ] **Step 2: Run the test to see it fail.**

Run: `swift test --package-path Packages/EnerGKit --filter aboveTheLimitWhileStillChargingIsCharging`
Expected: FAIL, because the state is `.limitDrain`.

- [ ] **Step 3: Implement.** In `Engine.state()`, change the Limit Drain line to:

```swift
        if let limit = effectiveLimit, snapshot.percent > limit, !snapshot.isCharging { return .limitDrain }
```

- [ ] **Step 4: Run all the tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Packages
git commit -m "fix: Limit Drain only once macOS stops charging"
```

---

### Task 4: NativeLimit polling fixes (stale read, re-apply then disable) and fake upgrades

**Files:**
- Modify: `Packages/EnerGKit/Tests/EnerGCoreTests/FakeLimitControls.swift` (whole file, shown below)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/NativeLimit.swift` (`set`, `waitUntilApplied`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/NativeLimitTests.swift`

**Interfaces:**
- Produces, on `FakeLimitControls`:
  - `var waits: [TimeInterval]`.
  - `var staleReads: Bool`.
  - `Daemon.appliesAfterWaits(Int)`. `Daemon` is now `Equatable`.

- [ ] **Step 1: Upgrade the fake.** Replace `FakeLimitControls.swift` with:

```swift
import Foundation
@testable import EnerGCore

/// Scripts how the smartcharging daemon reacts to an override; records every write.
final class FakeLimitControls: LimitControls {
    enum Call: Equatable {
        case setMCL(Int?), override(Int), notify, adapter(Bool)
    }
    enum Daemon: Equatable {
        /// Pushes the override to the SMC on the notification (the % happened to change).
        case appliesOnNotify
        /// Pushes it only on a plug event, i.e. the CHIE pulse (the % is steady).
        case appliesOnPulse
        /// Pushes it after this many `wait` calls (the daemon takes a moment).
        case appliesAfterWaits(Int)
        /// Never pushes it (a macOS that clamps the override).
        case neverApplies
    }

    var daemon = Daemon.appliesOnNotify
    var calls: [Call] = []
    /// Every `wait`, in seconds; kept out of `calls` so call sequences stay readable.
    var waits: [TimeInterval] = []
    /// What `CHLT[0]` holds; PowerUI writes land here at once.
    var chlt: Int? = 80
    /// A `CHLT` read after a change returns the value from before it, until the next `wait`.
    var staleReads = false
    var plugged = true
    var failingMCL = false
    var failingOverride = false
    /// Adapter-on writes that throw before one succeeds.
    var failingEnables = 0
    /// Adapter-off writes throw.
    var failingCut = false
    private var pending: Int?
    private var waitsLeft = 0
    private var isStale = false
    private var staleValue: Int?

    func setMCL(_ percent: Int?) throws {
        if failingMCL { throw HardwareError.io(-2) }
        calls.append(.setMCL(percent))
        setCHLT(percent)
        pending = nil
    }

    func writeOverride(_ percent: Int) throws {
        if failingOverride { throw HardwareError.io(-3) }
        calls.append(.override(percent))
        pending = percent
        if case .appliesAfterWaits(let n) = daemon { waitsLeft = n }
    }

    func notifyDefaultsChanged() {
        calls.append(.notify)
        if daemon == .appliesOnNotify, let pending { setCHLT(pending) }
    }

    func smcLimit() -> Int? { isStale ? staleValue : chlt }

    func pluggedIn() -> Bool { plugged }

    func setAdapter(enabled: Bool) throws {
        if !enabled, failingCut { throw HardwareError.io(-1) }
        if enabled, failingEnables > 0 {
            failingEnables -= 1
            throw HardwareError.io(-1)
        }
        calls.append(.adapter(enabled))
        if enabled, daemon == .appliesOnPulse, let pending { setCHLT(pending) }
    }

    func wait(_ seconds: TimeInterval) {
        waits.append(seconds)
        isStale = false
        guard case .appliesAfterWaits = daemon, let pending else { return }
        waitsLeft -= 1
        if waitsLeft == 0 { setCHLT(pending) }
    }

    /// Moves `CHLT`; with `staleReads`, reads keep the old value until the next `wait`.
    private func setCHLT(_ value: Int?) {
        if staleReads, !isStale {
            staleValue = chlt
            isStale = true
        }
        chlt = value
    }
}
```

- [ ] **Step 2: Run the tests.** The fake change alone keeps behaviour.

Run: `swift test --package-path Packages/EnerGKit --filter NativeLimitTests`
Expected: all pass.

- [ ] **Step 3: Write the new tests.** Add to `NativeLimitTests`:

```swift
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
```

- [ ] **Step 4: Run the tests to see which fail.**

Run: `swift test --package-path Packages/EnerGKit --filter NativeLimitTests`
Expected:
- `reapplyWaitsBeforeTheFirstPoll` FAILS: it returns 60 from the stale read.
- `adapterWasCutThenDisableRestoresEightyFirst` FAILS: the calls are `[.setMCL(nil), .setMCL(nil)]`.
- `belowEightyAppliedWithinTheSettleWindowNeedsNoPulse` and `eachPollWindowLastsTheSettleTime` PASS. They pin existing, previously untested behaviour.

- [ ] **Step 5: Implement.** In `NativeLimit.swift`, replace `set` and `waitUntilApplied` with:

```swift
    public func set(_ percent: Int?) throws -> Int? {
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
            return nil
        }
        if percent >= Self.powerUIMinimum {
            try controls.setMCL(percent)
            return percent
        }
        // A CHLT read straight after a write can return the old value, so after a re-apply it isn't trusted.
        if !reapplying, current == percent { return percent }
        if reapplying || current == nil { try controls.setMCL(Self.powerUIMinimum) }
        do {
            try controls.writeOverride(percent)
        } catch {
            return try fallBack()
        }
        controls.notifyDefaultsChanged()
        if waitUntilApplied(percent, afterReapply: reapplying) { return percent }
        guard controls.pluggedIn() else { return percent }
        // A failed cut leaves the override in place but nothing to apply it now.
        guard try pulse() else { return try fallBack() }
        if waitUntilApplied(percent, afterReapply: false) { return percent }
        return try fallBack()
    }
```

```swift
    /// `afterReapply`: the disable and `setMCL(80)` just went out, so the first read waits one poll, as it could be stale.
    private func waitUntilApplied(_ percent: Int, afterReapply: Bool) -> Bool {
        var waited: TimeInterval = 0
        if afterReapply {
            controls.wait(Self.pollInterval)
            waited += Self.pollInterval
        }
        while controls.smcLimit() != percent {
            if waited >= settle { return false }
            controls.wait(Self.pollInterval)
            waited += Self.pollInterval
        }
        return true
    }
```

- [ ] **Step 6: Run all the tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass. Make sure `adapterWasCutBelowEightyIgnoresTheStaleReading` and `disablingRestoresEightyFirst` still pass.

- [ ] **Step 7: Commit**

```bash
git add Packages
git commit -m "fix: a re-apply waits before trusting CHLT and keeps 80 when it then disables"
```

---

### Task 5: An adapter left cut by a pulse is retried once, not latched

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Hardware.swift` (protocol docs, `HardwareError`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/NativeLimit.swift` (`set` doc, `pulse`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Policy.swift` (`Session`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (`wakeReassertFailed` → `retryNextEvent`, `apply`, `write`)
- Modify: `Packages/EnerGKit/Tests/EnerGCoreTests/FakeHardware.swift`
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/NativeLimitTests.swift`, `LimitTests.swift`

**Interfaces:**
- Produces:
  - `HardwareError.adapterCut`.
  - `Session.adapterLeftCut: Bool`.
  - `FakeHardware.adapterCuts: Int`, the number of non-nil limit writes that throw `adapterCut` before one succeeds.

- [ ] **Step 1: Add the error and the fake knob.** In `Hardware.swift`:
  - Add a case to `HardwareError`:

```swift
    /// A pulse left the adapter cut: every re-enable failed. The next snapshot turns it back on.
    case adapterCut
```

  - Change the protocol header comment to:

```swift
/// Everything the Engine needs from the machine. Writes may throw; the Engine
/// then marks the matching `Feature` unavailable and stops writing it (`HardwareError.adapterCut` is retried once).
```

  - Add this line to the `setChargeLimit` doc:

```swift
    /// Throws `HardwareError.adapterCut` when a pulse left the adapter cut.
```

In `FakeHardware.swift`, add below `failingLimits`:

```swift
    /// Non-nil limit writes that throw `adapterCut` before one succeeds.
    var adapterCuts = 0
```

and in `setChargeLimit`, after the `failingLimits` line:

```swift
        if percent != nil, adapterCuts > 0 {
            adapterCuts -= 1
            throw HardwareError.adapterCut
        }
```

- [ ] **Step 2: Write the failing tests.**
  - In `NativeLimitTests`, replace `pulseThrowsWhenTheAdapterStaysCut` with:

```swift
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
```

  - In `LimitTests`, add:

```swift
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
```

- [ ] **Step 3: Run the tests to see them fail.**

Run: `swift test --package-path Packages/EnerGKit`
Expected:
- `adapterStaysCutThrowsAndTheNextSetReapplies` fails: the error is `io(-1)`, and there is no re-apply.
- `adapterCutIsRetriedOnTheNextEvent` and `aSuccessfulWriteResetsTheAdapterCutCount` fail: the Charge Limit is latched unavailable.
- `secondAdapterCutInARowLatches` may already pass.

- [ ] **Step 4: Implement NativeLimit.** In `pulse()`, replace the final `try controls.setAdapter(enabled: true)` / `return true` with:

```swift
        do {
            try controls.setAdapter(enabled: true)
        } catch {
            // The snapshot's heal turns it back on; the next set must then re-apply.
            adapterCut = true
            throw HardwareError.adapterCut
        }
        return true
```

Update the docs:
- On `pulse()`: `/// … returns false when the cut fails (the adapter was never cut); throws HardwareError.adapterCut when the adapter can't be turned back on.`
- On `set`, change "Throws when PowerUI fails or the adapter can't be turned back on after a pulse." to "Throws when PowerUI fails, or `HardwareError.adapterCut` when the adapter can't be turned back on after a pulse."

- [ ] **Step 5: Implement the Engine.**
  - In `Policy.swift` `Session`, add after `unavailable`:

```swift
    /// The last Charge Limit write left the adapter cut; a second one in a row makes it unavailable.
    var adapterLeftCut = false
```

  - In `Engine.swift`, rename `wakeReassertFailed` to `retryNextEvent` with the doc `/// A write is to be retried: the next event re-asserts everything.`. Then replace the tail of `apply` and the whole `write` with:

```swift
        applied = next
        if retryNextEvent {
            applied = nil
            retryNextEvent = false
        }
```

```swift
    /// Runs a hardware write unless the feature is already unavailable; a failure makes it unavailable, except during
    /// the wake re-assert and for a first `adapterCut`, where it is retried on the next event.
    private func write(_ feature: Feature, _ operation: () throws -> Void) {
        guard !session.unavailable.contains(feature) else { return }
        do {
            try operation()
            if feature == .chargeLimit { session.adapterLeftCut = false }
        } catch HardwareError.adapterCut where !session.adapterLeftCut {
            // The next snapshot turns the adapter back on, so the write is retried then.
            session.adapterLeftCut = true
            retryNextEvent = true
        } catch {
            if wakeReassert {
                retryNextEvent = true
            } else {
                session.unavailable.insert(feature)
            }
        }
    }
```

- [ ] **Step 6: Run all the tests and build the app.**

Run: `swift test --package-path Packages/EnerGKit`, then the app build. The build covers EnerGMac, which uses `HardwareError`.
Expected: all tests pass and the build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Packages
git commit -m "fix: an adapter left cut by a pulse retries the Charge Limit on the next event instead of latching it"
```

---

### Task 6: Re-set a sub-80 limit on plug-in

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (`evaluate`, `apply`, a new helper)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/NativeLimit.swift` (`set` doc)
- Modify: `Packages/EnerGKit/Tests/EnerGCoreTests/FakeHardware.swift` (`setChargeLimit`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/LimitTests.swift`

**Interfaces:**
- Consumes: `NativeLimit.powerUIMinimum` (public, 80).
- Produces: `Engine.apply(_ next: Actuation, reverifyLimit: Bool = false)` (private).

- [ ] **Step 1: Make the fake match the real unplugged behaviour.** In `FakeHardware.setChargeLimit`, change the clamp line to:

```swift
        // Unplugged, the real NativeLimit returns a value below 80 unverified: only the plug-in applies it.
        if let percent, percent < 80, !acceptsBelow80, snap.adapterConnected { return 80 }
```

and update the `acceptsBelow80` doc to `/// false: limits below 80 don't take and 80 is in effect instead, like a macOS that clamps the override (once plugged in).`

- [ ] **Step 2: Write the failing tests.** Add to `LimitTests`:

```swift
    // Set while unplugged, a limit below 80 is unverified; the plug-in re-sets it, so a clamping macOS shows 80.
    @Test func pluggingInReverifiesALimitBelowEighty() {
        let (engine, hw) = started { $0.acceptsBelow80 = false }
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        engine.handle(.powerChanged)
        #expect(engine.handle(.command(.setLimit(60))).effectiveLimit == 60)
        hw.writes.removeAll()
        hw.snap.adapterConnected = true
        let status = engine.handle(.powerChanged)
        #expect(hw.writes.contains(.limit(60)))
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
```

- [ ] **Step 3: Run the tests to see them fail.**

Run: `swift test --package-path Packages/EnerGKit --filter pluggingIn`
Expected: `pluggingInReverifiesALimitBelowEighty` FAILS, because nothing is written. `pluggingInLeavesALimitOfEightyOrMore` PASSES.

- [ ] **Step 4: Implement.** In `Engine.swift`:
  - In `evaluate()`, add `let previous = snapshot` as the first line.
  - Replace the final `apply(Policy.actuation(…))` with:

```swift
        apply(Policy.actuation(settings: settings, snapshot: current, session: session),
              reverifyLimit: needsReverify(from: previous, to: current))
```

  - Change the start of `apply` to:

```swift
    /// `reverifyLimit`: write the Charge Limit even if it is unchanged.
    private func apply(_ next: Actuation, reverifyLimit: Bool = false) {
        if reverifyLimit || changed(\.chargeLimit, to: next) {
```

  - Add below `apply`:

```swift
    /// A limit below 80 set while unplugged was returned unverified; the plug-in applies it, so it is set again to check.
    private func needsReverify(from previous: BatterySnapshot?, to current: BatterySnapshot) -> Bool {
        guard previous?.adapterConnected == false, current.adapterConnected,
              let requested = applied?.chargeLimit else { return false }
        return requested < NativeLimit.powerUIMinimum
    }
```

In `NativeLimit.set`'s doc, change "…`percent` is returned unverified, because the plug-in applies it." to "…`percent` is returned unverified, because the plug-in applies it; the Engine sets it again on plug-in to check."

- [ ] **Step 5: Run all the tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Packages
git commit -m "fix: a limit below 80 set while unplugged is re-set on plug-in"
```

---

### Task 7: Confirm a cut adapter before healing

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift` (`healAdapter`, around lines 58–67)

**Interfaces:** none new. There is no fake for MacHardware, so device check (e) in Task 9 covers this.

- [ ] **Step 1: Implement.** Replace `healAdapter()`'s first line (`guard let chie = try? read("CHIE", size: 1), chie[0] != 0x00 else { return }`) with:

```swift
        guard adapterReadsCut() else { return }
        // A read straight after a pulse's re-enable can return the old value: confirm before healing.
        wait(0.25)
        guard adapterReadsCut() else { return }
```

and add below `healAdapter()`:

```swift
    private func adapterReadsCut() -> Bool {
        guard let chie = try? read("CHIE", size: 1) else { return false }
        return chie[0] != 0x00
    }
```

- [ ] **Step 2: Build.**

Run: `swift build --package-path Packages/EnerGKit`
Expected: the build succeeds.

- [ ] **Step 3: Run the tests.**

Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add Packages
git commit -m "fix: heal the adapter only when CHIE still reads cut a moment later"
```

---

### Task 8: Smoke script and docs

**Files:**
- Modify: `scripts/smoke.sh`
- Modify: `docs/superpowers/specs/2026-10-21-energ-limits-redesign-design.md`
- Modify: `docs/superpowers/specs/2026-10-20-energ-design.md`
- Modify: `energd/EngineHost.swift` (the `shutdown` doc comment)
- README: no change. It has no Weak Adapter text (checked with `grep -in weak README.md`).
- `MacHardware.swift`: the "older build's Discharge" comment is kept on purpose.

- [ ] **Step 1: smoke.sh.**
  - Replace the header line `# Then: sudo scripts/smoke.sh     (quit AlDente first; watch the MagSafe LED)` with:

```bash
# Then: sudo scripts/smoke.sh     (quit AlDente first; watch the MagSafe LED)
# Suspend energd first, or its adapter heal undoes `adapter off`:
#   sudo launchctl kill SIGSTOP system/app.energ.energd     (afterwards: SIGCONT)
```

  - In `restore()`, replace `if [ "$ORIG" = off ]; then S limit off; else S limit "$ORIG"; fi` with:

```bash
  if [ "$ORIG" = off ]; then
    S limit off
  elif [ "$ORIG" -lt 50 ]; then
    echo "original limit $ORIG is below energ-smoke's 50...100; restoring 50"
    S limit 50
  else
    S limit "$ORIG"
  fi
```

Run: `bash -n scripts/smoke.sh`
Expected: no output.

- [ ] **Step 2: Limits redesign spec.** In `2026-10-21-energ-limits-redesign-design.md`, make these exact replacements:
  1. `` `adapterWasCut()` is called once at start (see below). `` → `` `adapterWasCut()` is called at every heal (see below). ``
  2. `Postcondition: the adapter is on when any call returns.` → ``Postcondition: the adapter is on when any call returns, except when `setChargeLimit` throws `HardwareError.adapterCut` (added in [Weak Adapter and cleanup](2026-10-21-energ-weak-adapter-and-cleanup-design.md)); the next snapshot turns it back on.``
  3. ``A failed re-enable is retried up to 3 times, 0.5 s apart; if all fail, `set` throws (Charge Limit unavailable) and MacHardware's snapshot turns the adapter back on at the next event.`` → ``The re-enable gets 3 attempts, 0.5 s apart. If all fail, `set` throws `adapterCut`, MacHardware's snapshot turns the adapter back on at the next event, and the Engine retries the write once then (see [Weak Adapter and cleanup](2026-10-21-energ-weak-adapter-and-cleanup-design.md)).``
  4. Delete the whole line that starts with `- **Stuck recovery** after a pulse above the new limit:`. The spike found no stuck state.
  5. Replace the `- **Weak Adapter sample:** …` bullet and its two sub-bullets ("The "first tick after a Discharge" skip goes." and "The skip for `.powerChanged` stays.") with:

```markdown
- **Weak Adapter:** superseded. It is now an adapter rated below 50 W, shown as information only; see [Weak Adapter and cleanup](2026-10-21-energ-weak-adapter-and-cleanup-design.md).
```

  6. In the `- **Limit Drain:** ` bullet under "Engine / Policy", change ``and `percent > effectiveLimit`. It replaces `.discharging`.`` to ``, `percent > effectiveLimit`, and not charging (the last condition was added in [Weak Adapter and cleanup](2026-10-21-energ-weak-adapter-and-cleanup-design.md)). It replaces `.discharging`.``

- [ ] **Step 3: Base spec.** In `2026-10-20-energ-design.md`:
  - Delete the whole bullet line starting `- **Sub-80 lowering at a steady % (2026-10-21, Mac17,8):**`.
  - Under `- **Sub-80 limits:**`, add this sub-bullet after `  - No chime or visible effect on the pulse.`:

```markdown
  - Lowering at a steady % (2026-10-21, Mac17,8): from 76 (`CHLT`=4c0505), writing 72 and posting the notification applied it right away (`CHLT`=480503, Limit Drain started), with no % tick or pulse. A `CHIE` pulse while draining above the new limit kept "AC Power" and left `CHLT` and the drain unchanged: no stuck state.
```

- [ ] **Step 4: EngineHost.** In `energd/EngineHost.swift`, rewrap the `shutdown` doc comment:

```swift
    /// Hands the LED back to macOS, then exits. Runs on the engine queue so no XPC or IOKit event can re-apply
    /// state between the stop and the exit.
```

- [ ] **Step 5: Build the app** (EngineHost changed).

Run: the app build from Global Constraints.
Expected: the build succeeds.

- [ ] **Step 6: Commit**

```bash
git add scripts/smoke.sh docs energd/EngineHost.swift
git commit -m "docs: smoke script suspends energd and clamps restore; spec nits after the Weak Adapter change"
```

---

### Task 9: Install and device checks (with the user)

The controller runs this with the user, after the final review and the merge. The user runs every `sudo` command.

- [ ] **Step 1: Install.**

Run: `scripts/install.sh` and `swift build --package-path Packages/EnerGKit --product energ-smoke`.
Then ask the user to run `sudo launchctl kickstart -k system/app.energ.energd`.

- [ ] **Step 2: Device checks** (spec section 6). Sample the state unprivileged with `Packages/EnerGKit/.build/debug/energ-smoke status` and `get-limit`. Record each outcome in the spec under a new `## Outcome` section.
  - (a) 30 W charger at the limit: the adapter row shows "30 W · light work", and still shows it during a Limit Drain (set a limit below the current %).
  - (b) 140 W charger: "140 W" while holding, "140 W · idle" during a Limit Drain.
  - (c) Lower the limit while charging: the popover shows "Charging" until macOS stops, then "Draining to N%".
  - (d) Unplug, set a limit below 80, plug in: `get-limit` shows `CHLT` = that limit, and there is no `lowLimitUnsupported` notice.
  - (e) The user runs `sudo launchctl kill SIGSTOP system/app.energ.energd`, then `sudo scripts/smoke.sh`, then `sudo launchctl kill SIGCONT system/app.energ.energd`: `adapter off` sticks for its 6 s, and the restore leaves the original limit. After SIGCONT, `energ-smoke status` shows the adapter connected and charging behaviour back to normal. That is the heal re-read path not misfiring.

- [ ] **Step 3: Commit the outcome.**

```bash
git add docs/superpowers/specs/2026-10-21-energ-weak-adapter-and-cleanup-design.md
git commit -m "docs: weak adapter and cleanup device check outcome"
```

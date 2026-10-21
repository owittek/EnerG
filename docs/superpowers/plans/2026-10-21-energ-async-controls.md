# Async Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The popover controls (Pause, Top Up, Charge Limit, MagSafe LED) respond instantly and never block, and the state line never blips (e.g. "Paused" → "Charging" → "Holding at 80%").

**Architecture:**
- EnerGCore gets three pure, unit-tested pieces:
  - `ChargeState.derive`: the Engine's state rule, pulled out of `Engine.state()`.
  - `Status.predicted`: the status energd will report once new settings apply.
  - `Reconciler`: a value type that holds what the user wants, sends one request at a time (latest click wins), and decides what the popover shows while a change settles.
- `AppModel` becomes a thin shell over XPC, timers and error strings. `PopoverView` calls a sync `model.change(_:)`.
- energd and the protocol are unchanged.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI app (XcodeGen), macOS 27.

Spec: `docs/superpowers/specs/2026-10-21-energ-async-controls-design.md`. Glossary: `CONTEXT.md`.

## Global Constraints

- Work on branch `footer-polish` in the main checkout (no worktree). Before Task 4, the footer changes in `EnerG/PopoverView.swift` must already be committed. If `git status` still shows that file modified when Task 4 starts, stop and ask the user.
- Run the tests with `swift test --package-path Packages/EnerGKit`. Every task ends with all tests passing.
- Build the app with: `xcodegen generate && xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug -derivedDataPath build -allowProvisioningUpdates build -quiet` (from the repo root). Run it in any task that touches `EnerG/` or a public EnerGCore API.
- Settle cap: **6 s** after the queue empties. Retry: every **1 s**, give up **10 s** after the first failure in a row. Poll: **0.5 s** while settling, **2 s** otherwise.
- Send order: paused → limit → topUp → LED.
- Copy, exact: `"Waiting for helper…"` and `"Helper not reachable — change not applied."`. Both use a single `…` (U+2026) and `—` (U+2014).
- Commit messages follow the repo style (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`), lower case. **Never** add `Co-Authored-By` or any Claude/AI attribution.
- Never commit `.superpowers/`. Never run `sudo`.
- Comments match the surrounding code: short doc comments that state the contract, wrapped at ~120 columns.

---

### Task 1: `ChargeState.derive` and `Status.predicted`

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Policy.swift` (append `ChargeState.derive`)
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Engine.swift` (`state()`)
- Create: `Packages/EnerGKit/Sources/EnerGCore/Prediction.swift`
- Create: `Packages/EnerGKit/Tests/EnerGCoreTests/StatusFixtures.swift`
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/PredictionTests.swift`

**Interfaces:**
- Produces:
  - `static func ChargeState.derive(paused: Bool, toppingUp: Bool, snapshot: BatterySnapshot?, effectiveLimit: Int?) -> ChargeState` (internal).
  - `public func Status.predicted(settings: Settings, toppingUp: Bool, chargingBefore: Bool) -> Status`.
  - Test fixture `func reported(_ settings: Settings = Settings(), percent: Int = 85, charging: Bool = false, toppingUp: Bool = false, plugged: Bool = true, warnings: [Warning] = []) -> Status`.

- [ ] **Step 1: Add the fixture.** Create `Tests/EnerGCoreTests/StatusFixtures.swift`:

```swift
@testable import EnerGCore

/// A Status as energd reports it, with the state and effective limit the Engine would derive.
func reported(_ settings: Settings = Settings(), percent: Int = 85, charging: Bool = false, toppingUp: Bool = false,
              plugged: Bool = true, warnings: [Warning] = []) -> Status {
    let active = toppingUp && !settings.paused && plugged
    let limit: Int? = settings.paused || active || settings.chargeLimit >= 100 ? nil : settings.chargeLimit
    let effective = warnings.contains(.lowLimitUnsupported) ? limit.map { max($0, 80) } : limit
    let snapshot = BatterySnapshot(percent: percent, isCharging: charging, adapterConnected: plugged,
                                   adapterWatts: 96, batteryWatts: 0, systemWatts: 10)
    return Status(state: .derive(paused: settings.paused, toppingUp: active, snapshot: snapshot,
                                 effectiveLimit: effective),
                  settings: settings, snapshot: snapshot, effectiveLimit: effective, toppingUp: active,
                  warnings: warnings)
}
```

- [ ] **Step 2: Write the failing tests.** Create `Tests/EnerGCoreTests/PredictionTests.swift`:

```swift
import Testing
@testable import EnerGCore

struct PredictionTests {
    /// Paused at `percent`, as before a Resume; macOS charges by default.
    private func paused(_ percent: Int, charging: Bool = true) -> Status {
        reported(Settings(paused: true), percent: percent, charging: charging)
    }

    private func resumed(_ status: Status) -> Status {
        var settings = status.settings
        settings.paused = false
        return status.predicted(settings: settings, toppingUp: false, chargingBefore: status.snapshot!.isCharging)
    }

    @Test func resumeDerivesTheStateFromBatteryAndLimit() {
        #expect(resumed(paused(85)).stateLabel == "Draining to 80%")
        #expect(resumed(paused(85)).effectiveLimit == 80)
        #expect(resumed(paused(80)).stateLabel == "Holding at 80%")
        #expect(resumed(paused(70, charging: false)).stateLabel == "Charging")
    }

    @Test func bandKeepsTheChargingStateFromBefore() {
        #expect(resumed(paused(77)).stateLabel == "Charging")
        #expect(resumed(paused(77, charging: false)).stateLabel == "Not charging · resumes below 75%")
    }

    @Test func pauseAndTopUp() {
        let holding = reported(percent: 80)
        var settings = holding.settings
        settings.paused = true
        let pausing = holding.predicted(settings: settings, toppingUp: true, chargingBefore: false)
        #expect(pausing.state == .paused)
        #expect(pausing.effectiveLimit == nil)
        #expect(!pausing.toppingUp)
        let toppingUp = holding.predicted(settings: holding.settings, toppingUp: true, chargingBefore: false)
        #expect(toppingUp.state == .toppingUp)
        #expect(toppingUp.effectiveLimit == nil)
    }

    @Test func topUpWhileUnpluggedEndsAtOnce() {
        let unplugged = reported(percent: 70, plugged: false)
        let predicted = unplugged.predicted(settings: unplugged.settings, toppingUp: true, chargingBefore: false)
        #expect(!predicted.toppingUp)
        #expect(predicted.state == .onBattery)
    }

    @Test func lowLimitPredictsTheFallbackOnceItIsKnown() {
        var settings = Settings(chargeLimit: 60)
        let unknown = reported(percent: 85).predicted(settings: settings, toppingUp: false, chargingBefore: false)
        #expect(unknown.effectiveLimit == 60)
        #expect(unknown.stateLabel == "Draining to 60%")
        let fallenBack = reported(Settings(chargeLimit: 70), percent: 85, warnings: [.lowLimitUnsupported])
        let known = fallenBack.predicted(settings: settings, toppingUp: false, chargingBefore: false)
        #expect(known.effectiveLimit == 80)
        #expect(known.warnings == [.lowLimitUnsupported])
        #expect(known.stateLabel == "Draining to 80%")
        settings.chargeLimit = 90
        #expect(fallenBack.predicted(settings: settings, toppingUp: false, chargingBefore: false).warnings.isEmpty)
    }

    @Test func noLimitAndUnreadable() {
        let full = reported(percent: 100)
        let noLimit = full.predicted(settings: Settings(chargeLimit: 100), toppingUp: false, chargingBefore: false)
        #expect(noLimit.effectiveLimit == nil)
        #expect(noLimit.state == .atLimit)
        let unreadable = Status(state: .unknown, settings: Settings(), snapshot: nil, effectiveLimit: nil,
                                toppingUp: false, warnings: [.batteryUnreadable])
        #expect(unreadable.predicted(settings: Settings(), toppingUp: false, chargingBefore: false).state == .unknown)
    }
}
```

- [ ] **Step 3: Run to verify it fails.**
Run: `swift test --package-path Packages/EnerGKit --filter PredictionTests`
Expected: compile error, `derive` / `predicted` not found.

- [ ] **Step 4: Extract `derive`.** Append to `Policy.swift`:

```swift
extension ChargeState {
    /// The Engine's state rule; `Status.predicted` uses it too, so a prediction can't drift from what energd reports.
    static func derive(paused: Bool, toppingUp: Bool, snapshot: BatterySnapshot?, effectiveLimit: Int?) -> ChargeState {
        if paused { return .paused }
        guard let snapshot else { return .unknown }
        if toppingUp { return .toppingUp }
        if !snapshot.adapterConnected { return .onBattery }
        if let limit = effectiveLimit, snapshot.percent > limit, !snapshot.isCharging { return .limitDrain }
        return snapshot.isCharging ? .charging : .atLimit
    }
}
```

In `Engine.swift`, replace the body of `state()` with:

```swift
    private func state() -> ChargeState {
        .derive(paused: paused, toppingUp: session.toppingUp, snapshot: snapshot, effectiveLimit: effectiveLimit)
    }
```

- [ ] **Step 5: Add the prediction.** Create `Sources/EnerGCore/Prediction.swift`:

```swift
extension Status {
    /// The status energd is expected to report once `settings` and `toppingUp` are applied, from this status's
    /// snapshot and warnings. While plugged in and not paused, the snapshot's `isCharging` is re-derived from the new
    /// limit (100 when there is none): off at or above it, `chargingBefore` in the firmware's 5-point band below it,
    /// on further below. A limit below 80 is predicted as 80 once `lowLimitUnsupported` has been reported.
    public func predicted(settings: Settings, toppingUp: Bool, chargingBefore: Bool) -> Status {
        let plugged = snapshot?.adapterConnected ?? true
        let topUp = toppingUp && !settings.paused && plugged
        let requested: Int? = settings.paused || topUp || settings.chargeLimit >= 100 ? nil : settings.chargeLimit
        var effective = requested
        if let limit = requested, limit < NativeLimit.powerUIMinimum, warnings.contains(.lowLimitUnsupported) {
            effective = NativeLimit.powerUIMinimum
        }
        if warnings.contains(.unavailable(.chargeLimit)) { effective = nil }
        var newWarnings = warnings.filter { $0 != .lowLimitUnsupported }
        if let effective, let requested, effective > requested { newWarnings.insert(.lowLimitUnsupported, at: 0) }
        var battery = snapshot
        if var s = battery, s.adapterConnected, !settings.paused {
            let ceiling = effective ?? 100
            s.isCharging = s.percent >= ceiling ? false : s.percent >= ceiling - 5 ? chargingBefore : true
            battery = s
        }
        return Status(state: .derive(paused: settings.paused, toppingUp: topUp, snapshot: battery,
                                     effectiveLimit: effective),
                      settings: settings, snapshot: battery, effectiveLimit: effective, toppingUp: topUp,
                      warnings: newWarnings)
    }
}
```

- [ ] **Step 6: Run all tests.**
Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass, including the existing Engine tests that now go through `derive`.

- [ ] **Step 7: Commit.**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/Policy.swift Packages/EnerGKit/Sources/EnerGCore/Engine.swift \
  Packages/EnerGKit/Sources/EnerGCore/Prediction.swift Packages/EnerGKit/Tests/EnerGCoreTests/StatusFixtures.swift \
  Packages/EnerGKit/Tests/EnerGCoreTests/PredictionTests.swift
git commit -m "feat: predict the status a settings change will report"
```

---

### Task 2: `Reconciler` queue and retries

**Files:**
- Create: `Packages/EnerGKit/Sources/EnerGCore/Reconciler.swift`
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/ReconcilerTests.swift`

**Interfaces:**
- Consumes: `reported(...)` fixture (Task 1).
- Produces (all on `public struct Reconciler`):
  - `public init()`
  - `public struct Token: Equatable, Sendable`
  - `public enum FailureOutcome: Equatable, Sendable { case stale, retry, gaveUp }`
  - `public static let retryWindow: Duration` (10 s)
  - `public mutating func want(_ request: Request, now: ContinuousClock.Instant)`
  - `public mutating func nextCommand() -> (Request, Token)?`
  - `public mutating func beginPoll() -> Token?`
  - `@discardableResult public mutating func received(_ status: Status, for token: Token, now: ContinuousClock.Instant) -> Bool`
  - `public mutating func failed(_ token: Token, now: ContinuousClock.Instant) -> FailureOutcome`
  - `public var waitingForHelper: Bool`
  - `public mutating func reset()`

Behaviour:
- One request in flight at a time, polls included, so replies arrive in order.
- A want that matches the confirmed status and isn't in flight is dropped, so clicks that cancel out send nothing.
- A field never counts as done while its own request is in flight.
- After a field's own reply, if energd still reports the old value for exactly what was sent, the request was refused and is dropped.
- Pause drops a wanted Top Up.

- [ ] **Step 1: Write the failing tests.** Create `Tests/EnerGCoreTests/ReconcilerTests.swift`:

```swift
import Testing
@testable import EnerGCore

private let start = ContinuousClock.now

/// `seconds` after the start of the test clock.
private func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

/// A Reconciler that has received `status` from its first poll.
private func ready(_ status: Status) -> Reconciler {
    var reconciler = Reconciler()
    let token = reconciler.beginPoll()!
    reconciler.received(status, for: token, now: at(0))
    return reconciler
}

struct ReconcilerQueueTests {
    @Test func latestClickWinsWhileARequestIsInFlight() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (first, token) = r.nextCommand()!
        #expect(first == .setPaused(true))
        r.want(.setPaused(false), now: at(0.1))
        r.want(.setPaused(true), now: at(0.2))
        let whileInFlight = r.nextCommand()?.0
        #expect(whileInFlight == nil)
        r.received(reported(Settings(paused: true), percent: 80), for: token, now: at(0.3))
        let afterReply = r.nextCommand()?.0
        #expect(afterReply == nil)
    }

    @Test func pauseThenResumeWhileInFlightSendsTheResume() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, token) = r.nextCommand()!
        r.want(.setPaused(false), now: at(0.1))
        r.received(reported(Settings(paused: true), percent: 80), for: token, now: at(0.3))
        let next = r.nextCommand()?.0
        #expect(next == .setPaused(false))
    }

    @Test func clicksThatCancelOutSendNothing() {
        var r = ready(reported(percent: 80))
        let poll = r.beginPoll()!
        r.want(.setPaused(true), now: at(0))
        r.want(.setPaused(false), now: at(0.1))
        r.received(reported(percent: 80), for: poll, now: at(0.2))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func aPollAnsweredBeforeTheRequestRunsDoesNotForgetIt() {
        var r = ready(reported(Settings(paused: true)))
        let poll = r.beginPoll()!
        r.want(.setPaused(false), now: at(0))
        r.received(reported(Settings(paused: true)), for: poll, now: at(0.1))
        let blockedPoll = r.beginPoll()
        #expect(blockedPoll == nil)
        let next = r.nextCommand()?.0
        #expect(next == .setPaused(false))
    }

    @Test func sendOrderIsPausedLimitTopUpLED() {
        var r = ready(reported(percent: 70))
        r.want(.setLEDMode(.off), now: at(0))
        let (led, token) = r.nextCommand()!
        #expect(led == .setLEDMode(.off))
        r.want(.topUp, now: at(0.1))
        r.want(.setLimit(90), now: at(0.1))
        r.received(reported(Settings(ledMode: .off), percent: 70), for: token, now: at(0.2))
        let next = r.nextCommand()?.0
        #expect(next == .setLimit(90))
    }

    @Test func pauseDropsAWantedTopUp() {
        var r = ready(reported(percent: 85))
        r.want(.topUp, now: at(0))
        r.want(.setPaused(true), now: at(0.1))
        let (request, token) = r.nextCommand()!
        #expect(request == .setPaused(true))
        r.received(reported(Settings(paused: true), percent: 85), for: token, now: at(0.3))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func followsATopUpEndedByEnergd() {
        var r = ready(reported(percent: 99, toppingUp: true))
        r.want(.setLEDMode(.off), now: at(0))
        let (_, token) = r.nextCommand()!
        r.received(reported(Settings(ledMode: .off), percent: 100, toppingUp: false), for: token, now: at(0.3))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func aRefusedRequestIsDropped() {
        var r = ready(reported(percent: 85, plugged: false))
        r.want(.topUp, now: at(0))
        let (request, token) = r.nextCommand()!
        #expect(request == .topUp)
        r.received(reported(percent: 85, plugged: false), for: token, now: at(0.3))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func clicksBeforeTheFirstStatusAreIgnored() {
        var r = Reconciler()
        r.want(.setPaused(true), now: at(0))
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func repliesFromBeforeAResetAreStale() {
        var r = Reconciler()
        let poll = r.beginPoll()!
        r.reset()
        let applied = r.received(reported(), for: poll, now: at(0))
        #expect(!applied)
        let outcome = r.failed(poll, now: at(0))
        #expect(outcome == .stale)
        let fresh = r.beginPoll()
        #expect(fresh != nil)
    }

    @Test func aShortOutageIsRetried() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, first) = r.nextCommand()!
        let outcome = r.failed(first, now: at(0))
        #expect(outcome == .retry)
        #expect(r.waitingForHelper)
        let (again, second) = r.nextCommand()!
        #expect(again == .setPaused(true))
        r.received(reported(Settings(paused: true), percent: 80), for: second, now: at(3))
        #expect(!r.waitingForHelper)
    }

    @Test func aLongOutageGivesUpAfterTheRetryWindow() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        for second in 0..<10 {
            let (_, token) = r.nextCommand()!
            let outcome = r.failed(token, now: at(Double(second)))
            #expect(outcome == .retry)
        }
        let (_, last) = r.nextCommand()!
        let outcome = r.failed(last, now: at(10))
        #expect(outcome == .gaveUp)
        #expect(!r.waitingForHelper)
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func aClickDuringTheRetryWindowReplacesThePendingChange() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let (_, token) = r.nextCommand()!
        _ = r.failed(token, now: at(0))
        r.want(.setPaused(false), now: at(0.5))
        #expect(!r.waitingForHelper)
        let next = r.nextCommand()?.0
        #expect(next == nil)
    }

    @Test func aFailedPollIsNotRetriedHere() {
        var r = Reconciler()
        let poll = r.beginPoll()!
        let outcome = r.failed(poll, now: at(0))
        #expect(outcome == .retry)
        #expect(!r.waitingForHelper)
        let next = r.beginPoll()
        #expect(next != nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
Run: `swift test --package-path Packages/EnerGKit --filter ReconcilerQueueTests`
Expected: compile error, `Reconciler` not found.

- [ ] **Step 3: Implement.** Create `Sources/EnerGCore/Reconciler.swift`:

```swift
/// The popover's side of the controls. Clicks change what the user wants at once; requests to energd go out one at a
/// time, polls included, and the latest click on a control wins. Use from one actor; time is passed in.
public struct Reconciler {
    /// One request sent to energd. Pass it back with its reply or failure.
    public struct Token: Equatable, Sendable {
        fileprivate let seq: Int
        fileprivate let isPoll: Bool
    }

    public enum FailureOutcome: Equatable, Sendable {
        /// From before a `reset`, or already answered: ignore it.
        case stale
        /// Wait a second, then send what `nextCommand` returns. Also returned for a poll, which isn't retried here.
        case retry
        /// energd stayed unreachable for `retryWindow`: every pending change was dropped.
        case gaveUp
    }

    /// How long failed changes are retried, from the first failure in a row, before they are dropped.
    public static let retryWindow: Duration = .seconds(10)

    /// Declared in send order.
    private enum Field: CaseIterable { case paused, limit, topUp, led }

    /// Per control, the value the user wants; nil follows what energd reports.
    private struct Wants: Equatable {
        var paused: Bool?
        var limit: Int?
        var topUp: Bool?
        var led: LEDMode?
    }

    private struct InFlight {
        let token: Token
        /// The field and the request sent for it; nil for a poll.
        let sent: (field: Field, request: Request)?
    }

    private var confirmed: Status?
    private var wants = Wants()
    private var inFlight: InFlight?
    private var firstFailure: ContinuousClock.Instant?
    private var seq = 0
    /// Tokens up to this one are from before the last `reset`.
    private var resetSeq = 0

    public init() {}

    /// A click: `setPaused`, `setLimit`, `topUp`, `cancelTopUp` or `setLEDMode`; other requests are ignored, as is a
    /// click before the first status arrives. Pause also drops a wanted Top Up, as energd clears it.
    public mutating func want(_ request: Request, now: ContinuousClock.Instant) {
        guard confirmed != nil else { return }
        switch request {
        case .setPaused(let paused):
            wants.paused = paused
            if paused { wants.topUp = nil }
        case .setLimit(let limit): wants.limit = limit
        case .topUp: wants.topUp = true
        case .cancelTopUp: wants.topUp = false
        case .setLEDMode(let mode): wants.led = mode
        case .getStatus, .release: return
        }
        prune()
    }

    /// The next change to send, or nil while a request is in flight or nothing differs from the confirmed status.
    public mutating func nextCommand() -> (Request, Token)? {
        guard inFlight == nil, let confirmed else { return nil }
        for field in Field.allCases {
            guard let request = request(for: field, confirmed) else { continue }
            let token = issue(isPoll: false)
            inFlight = InFlight(token: token, sent: (field, request))
            return (request, token)
        }
        return nil
    }

    /// A token for a `getStatus`, or nil while a request is in flight or a change waits to be sent.
    public mutating func beginPoll() -> Token? {
        guard inFlight == nil, !hasPendingChange else { return nil }
        let token = issue(isPoll: true)
        inFlight = InFlight(token: token, sent: nil)
        return token
    }

    /// A reply to a command or poll. Returns false for a token from before a `reset`, which changes nothing.
    @discardableResult
    public mutating func received(_ status: Status, for token: Token, now: ContinuousClock.Instant) -> Bool {
        guard token.seq > resetSeq else { return false }
        let own = inFlight?.token == token ? inFlight : nil
        if own != nil { inFlight = nil }
        confirmed = status
        firstFailure = nil
        // energd kept the old value for exactly what was sent (e.g. Top Up while unplugged): stop asking.
        if let sent = own?.sent, request(for: sent.field, status) == sent.request { clear(sent.field) }
        prune()
        return true
    }

    /// The request for `token` didn't reach energd.
    public mutating func failed(_ token: Token, now: ContinuousClock.Instant) -> FailureOutcome {
        guard token.seq > resetSeq, inFlight?.token == token else { return .stale }
        inFlight = nil
        guard !token.isPoll else { return .retry }
        let first = firstFailure ?? now
        firstFailure = first
        guard first.duration(to: now) >= Self.retryWindow else { return .retry }
        wants = Wants()
        firstFailure = nil
        return .gaveUp
    }

    /// A change failed and is waiting to be retried.
    public var waitingForHelper: Bool { firstFailure != nil }

    /// Forgets everything, e.g. after an uninstall; replies to earlier tokens are then stale.
    public mutating func reset() {
        let last = seq
        self = Reconciler()
        seq = last
        resetSeq = last
    }

    private var hasPendingChange: Bool {
        guard let confirmed else { return false }
        return Field.allCases.contains { request(for: $0, confirmed) != nil }
    }

    /// No change in flight and nothing left to send.
    private var queueEmpty: Bool { inFlight?.sent == nil && wants == Wants() }

    /// Drops wants energd already reports, except the one in flight.
    private mutating func prune() {
        guard let confirmed else { return }
        for field in Field.allCases where inFlight?.sent?.field != field && request(for: field, confirmed) == nil {
            clear(field)
        }
        if queueEmpty { firstFailure = nil }
    }

    /// The request that moves `field` from `confirmed` to what is wanted; nil when nothing is wanted or they match.
    /// Pause compares with the state, so it also ends a `release`.
    private func request(for field: Field, _ confirmed: Status) -> Request? {
        switch field {
        case .paused:
            guard let paused = wants.paused, paused != (confirmed.state == .paused) else { return nil }
            return .setPaused(paused)
        case .limit:
            guard let limit = wants.limit, limit != confirmed.settings.chargeLimit else { return nil }
            return .setLimit(limit)
        case .topUp:
            guard let topUp = wants.topUp, topUp != confirmed.toppingUp else { return nil }
            return topUp ? .topUp : .cancelTopUp
        case .led:
            guard let mode = wants.led, mode != confirmed.settings.ledMode else { return nil }
            return .setLEDMode(mode)
        }
    }

    private mutating func clear(_ field: Field) {
        switch field {
        case .paused: wants.paused = nil
        case .limit: wants.limit = nil
        case .topUp: wants.topUp = nil
        case .led: wants.led = nil
        }
    }

    private mutating func issue(isPoll: Bool) -> Token {
        seq += 1
        return Token(seq: seq, isPoll: isPoll)
    }
}
```

- [ ] **Step 4: Run all tests.**
Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 5: Commit.**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/Reconciler.swift Packages/EnerGKit/Tests/EnerGCoreTests/ReconcilerTests.swift
git commit -m "feat: queue control changes, latest click wins, with retries"
```

---

### Task 3: `Reconciler` display and settle

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Reconciler.swift`
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/ReconcilerTests.swift` (append a second suite)

**Interfaces:**
- Consumes: `Status.predicted` (Task 1); the Task 2 `Reconciler`.
- Produces:
  - `public static let settleCap: Duration` (6 s)
  - `public func displayed(now: ContinuousClock.Instant) -> Status?`
  - `public func isSettling(now: ContinuousClock.Instant) -> Bool`
  - `public var settleDeadline: ContinuousClock.Instant?`
  - `public mutating func closed(now: ContinuousClock.Instant)`

Behaviour:
- A click starts a *settle* unless one is running. It records the confirmed status at that moment as the *baseline*, whose charging state the band prediction uses until the settle ends.
- While settling, `displayed` is the prediction. The charge state is re-derived only when Pause, the Charge Limit or Top Up differ from the confirmed status or from the baseline. Otherwise it is the confirmed status with the wanted LED mode.
- The settle ends when the queue is empty and the confirmed `state` and `stateLabel` equal the prediction's, or `settleCap` after the queue emptied.
- `closed` freezes `displayed` until a poll issued after it answers.
- Giving up ends the settle.

- [ ] **Step 1: Write the failing tests.** Append to `ReconcilerTests.swift`:

```swift
struct ReconcilerDisplayTests {
    /// Paused at `percent` with limit `limit`, macOS charging.
    private func pausedAt(_ percent: Int, limit: Int = 80, charging: Bool = true) -> Reconciler {
        ready(reported(Settings(chargeLimit: limit, paused: true), percent: percent, charging: charging))
    }

    @Test func resumeShowsThePredictionAndHidesTheStaleCharging() {
        var r = pausedAt(85)
        r.want(.setPaused(false), now: at(0))
        #expect(r.displayed(now: at(0))?.stateLabel == "Draining to 80%")
        let (_, token) = r.nextCommand()!
        r.received(reported(percent: 85, charging: true), for: token, now: at(0.3))
        #expect(r.displayed(now: at(0.4))?.stateLabel == "Draining to 80%")
        #expect(r.isSettling(now: at(0.4)))
        let poll = r.beginPoll()!
        r.received(reported(percent: 85), for: poll, now: at(2))
        #expect(!r.isSettling(now: at(2)))
        #expect(r.displayed(now: at(2))?.stateLabel == "Draining to 80%")
    }

    @Test func theCapStartsWhenTheQueueEmpties() {
        var r = pausedAt(70, limit: 60)
        r.want(.setPaused(false), now: at(0))
        #expect(r.settleDeadline == nil)
        let (_, token) = r.nextCommand()!
        r.received(reported(Settings(chargeLimit: 60), percent: 70, charging: true), for: token, now: at(5))
        #expect(r.settleDeadline == at(11))
        #expect(r.displayed(now: at(10.9))?.stateLabel == "Draining to 60%")
        #expect(r.displayed(now: at(11.1))?.stateLabel == "Charging")
        #expect(!r.isSettling(now: at(11.1)))
    }

    @Test func pauseShowsPausedAtOnce() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        let shown = r.displayed(now: at(0))
        #expect(shown?.state == .paused)
        #expect(shown?.settings.paused == true)
    }

    @Test func aRejectedLowLimitCorrectsOnceTo80() {
        var r = ready(reported(percent: 85))
        r.want(.setLimit(60), now: at(0))
        #expect(r.displayed(now: at(0))?.stateLabel == "Draining to 60%")
        let (_, token) = r.nextCommand()!
        r.received(reported(Settings(chargeLimit: 60), percent: 85, warnings: [.lowLimitUnsupported]),
                   for: token, now: at(5))
        #expect(!r.isSettling(now: at(5)))
        #expect(r.displayed(now: at(5))?.stateLabel == "Draining to 80%")
    }

    @Test func theBandUsesTheChargingStateFromBeforeTheClick() {
        var r = pausedAt(77, charging: false)
        r.want(.setPaused(false), now: at(0))
        #expect(r.displayed(now: at(0))?.stateLabel == "Not charging · resumes below 75%")
        let (_, token) = r.nextCommand()!
        r.received(reported(percent: 77, charging: true), for: token, now: at(0.3))
        #expect(r.displayed(now: at(0.4))?.stateLabel == "Not charging · resumes below 75%")
        let poll = r.beginPoll()!
        r.received(reported(percent: 77), for: poll, now: at(2))
        #expect(!r.isSettling(now: at(2)))
    }

    @Test func anLEDChangeLeavesTheChargeStateAsReported() {
        var r = ready(reported(percent: 70))
        r.want(.setLEDMode(.off), now: at(0))
        let shown = r.displayed(now: at(0))
        #expect(shown?.stateLabel == "Not charging")
        #expect(shown?.settings.ledMode == .off)
    }

    @Test func reopeningHoldsWhatWasShownUntilAFreshPoll() {
        var r = pausedAt(85)
        r.want(.setPaused(false), now: at(0))
        let (_, token) = r.nextCommand()!
        r.closed(now: at(0.2))
        r.received(reported(percent: 85, charging: true), for: token, now: at(5))
        #expect(r.displayed(now: at(12))?.stateLabel == "Draining to 80%")
        let poll = r.beginPoll()!
        r.received(reported(percent: 85), for: poll, now: at(12.2))
        #expect(r.displayed(now: at(12.2))?.stateLabel == "Draining to 80%")
        #expect(!r.isSettling(now: at(12.2)))
    }

    @Test func aPollSentBeforeClosingDoesNotEndTheHold() {
        var r = ready(reported(percent: 80))
        let early = r.beginPoll()!
        r.closed(now: at(0))
        r.received(reported(percent: 79), for: early, now: at(0.2))
        #expect(r.displayed(now: at(0.3))?.stateLabel == "Holding at 80%")
        let fresh = r.beginPoll()!
        r.received(reported(percent: 79), for: fresh, now: at(1))
        #expect(r.displayed(now: at(1))?.stateLabel == "Not charging · resumes below 75%")
    }

    @Test func retriesKeepThePredictionAndGivingUpShowsTheTruth() {
        var r = ready(reported(percent: 80))
        r.want(.setPaused(true), now: at(0))
        for second in 0..<10 {
            let (_, token) = r.nextCommand()!
            _ = r.failed(token, now: at(Double(second)))
            #expect(r.displayed(now: at(Double(second)))?.state == .paused)
        }
        let (_, last) = r.nextCommand()!
        let outcome = r.failed(last, now: at(10))
        #expect(outcome == .gaveUp)
        #expect(r.displayed(now: at(10))?.stateLabel == "Holding at 80%")
        #expect(!r.isSettling(now: at(10)))
    }
}
```

- [ ] **Step 2: Run to verify it fails.**
Run: `swift test --package-path Packages/EnerGKit --filter ReconcilerDisplayTests`
Expected: compile error, `displayed` / `isSettling` / `settleDeadline` / `closed` not found.

- [ ] **Step 3: Implement.** In `Reconciler.swift`:

3a. Extend the type's doc comment with the sentence: `While a change settles, `displayed` shows the status predicted for it instead of a reply that may still be stale.`

3b. Below `retryWindow`, add:

```swift
    /// How long the prediction stays once nothing is left to send, if no confirmed status agrees with it first.
    public static let settleCap: Duration = .seconds(6)
```

3c. Below `struct InFlight`, add:

```swift
    private struct Settle {
        /// The confirmed status at the first click; the band prediction keeps its charging state.
        let baseline: Status
        /// When nothing was left to send; nil while something is.
        var drainedAt: ContinuousClock.Instant? = nil
    }
```

3d. Below `private var resetSeq = 0`, add:

```swift
    private var settle: Settle?
    /// Shown from `closed` until a poll sent after it answers.
    private var frozen: Status?
    private var closedSeq = 0
```

3e. In `want`, change `guard confirmed != nil else { return }` to `guard let confirmed else { return }`. Replace the final `prune()` with:

```swift
        if settle.map({ expired($0, now) }) ?? true { settle = Settle(baseline: confirmed) }
        prune()
        updateSettle(now)
```

3f. In `received`, replace the final `prune()` / `return true` with:

```swift
        if token.isPoll, token.seq > closedSeq { frozen = nil }
        prune()
        updateSettle(now)
        return true
```

3g. In `failed`, after `wants = Wants()`, add `settle = nil`.

3h. Below `waitingForHelper`, add:

```swift
    /// What the popover shows: the prediction while a change settles, else the confirmed status; from `closed` until
    /// a poll sent after it answers, what was shown at `closed`. nil before the first status.
    public func displayed(now: ContinuousClock.Instant) -> Status? {
        if let frozen { return frozen }
        guard let confirmed else { return nil }
        guard let settle, !expired(settle, now) else { return confirmed }
        return prediction(confirmed, settle)
    }

    /// A change is settling, so polls should come faster.
    public func isSettling(now: ContinuousClock.Instant) -> Bool {
        settle.map { !expired($0, now) } ?? false
    }

    /// When the prediction gives way to the confirmed status unless one agrees first; nil while something is left to
    /// send or nothing is settling.
    public var settleDeadline: ContinuousClock.Instant? { settle?.drainedAt.map { $0 + Self.settleCap } }

    /// The popover closed: keep showing what it showed until a poll sent after this answers, since replies arriving
    /// meanwhile may be stale.
    public mutating func closed(now: ContinuousClock.Instant) {
        frozen = displayed(now: now)
        closedSeq = seq
    }
```

3i. Above `private func request(for:_:)`, add:

```swift
    private func expired(_ settle: Settle, _ now: ContinuousClock.Instant) -> Bool {
        settle.drainedAt.map { $0.duration(to: now) >= Self.settleCap } ?? false
    }

    /// Notes when the queue emptied; ends the settle once nothing is left to send and the confirmed status agrees
    /// with the prediction, or at the cap.
    private mutating func updateSettle(_ now: ContinuousClock.Instant) {
        guard var settle, let confirmed else { return }
        guard queueEmpty else {
            settle.drainedAt = nil
            self.settle = settle
            return
        }
        if settle.drainedAt == nil { settle.drainedAt = now }
        let shown = prediction(confirmed, settle)
        let agrees = shown.state == confirmed.state && shown.stateLabel == confirmed.stateLabel
        self.settle = agrees || expired(settle, now) ? nil : settle
    }

    /// The confirmed status with the wanted settings applied. The charge state is re-derived only when Pause, the
    /// Charge Limit or Top Up differ from the confirmed status or from the baseline; otherwise it stays as reported.
    private func prediction(_ confirmed: Status, _ settle: Settle) -> Status {
        var settings = confirmed.settings
        settings.paused = wants.paused ?? (confirmed.state == .paused)
        settings.chargeLimit = wants.limit ?? confirmed.settings.chargeLimit
        settings.ledMode = wants.led ?? confirmed.settings.ledMode
        let toppingUp = wants.topUp ?? confirmed.toppingUp
        let wanted = (settings.paused, settings.chargeLimit, toppingUp)
        let base = settle.baseline
        if wanted == (confirmed.state == .paused, confirmed.settings.chargeLimit, confirmed.toppingUp),
           wanted == (base.state == .paused, base.settings.chargeLimit, base.toppingUp) {
            var shown = confirmed
            shown.settings.ledMode = settings.ledMode
            return shown
        }
        return confirmed.predicted(settings: settings, toppingUp: toppingUp,
                                   chargingBefore: base.snapshot?.isCharging ?? false)
    }
```

- [ ] **Step 4: Run all tests.**
Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass, including `ReconcilerQueueTests`.

- [ ] **Step 5: Commit.**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/Reconciler.swift Packages/EnerGKit/Tests/EnerGCoreTests/ReconcilerTests.swift
git commit -m "feat: show the predicted status until a change settles"
```

---

### Task 4: Wire `AppModel` and `PopoverView`

**Files:**
- Modify: `EnerG/AppModel.swift`
- Modify: `EnerG/PopoverView.swift` (`BatteryTile`, `ControlGrid`)

**Interfaces:**
- Consumes: `Reconciler` (Tasks 2 and 3).
- Produces: `AppModel.status: Status?` (now the displayed status, `private(set)`), `AppModel.waitingForHelper: Bool`, `AppModel.change(_ request: Request)`. Removes `AppModel.perform(_:)` and `AppModel.send(_:)`.

No unit tests: the logic is in `Reconciler`. Verify by building and on the device.

- [ ] **Step 1: Check the precondition.** Run `git status --short EnerG/PopoverView.swift`. If it prints anything, stop and ask the user to commit the footer work first.

- [ ] **Step 2: Rewrite the state and the request path in `AppModel.swift`.**

Replace the `status` property:

```swift
    /// What the popover shows: the predicted status while a change settles, else the last reply. nil before the first.
    private(set) var status: Status?
    /// A change couldn't reach the helper and is being retried.
    private(set) var waitingForHelper = false
```

Replace the private stored properties block (`client` … `appliedSeq`) with:

```swift
    private let client = DaemonClient()
    private var reconciler = Reconciler()
    private var polling: Task<Void, Never>?
    /// Sends queued changes; keeps running while the popover is closed.
    private var sender: Task<Void, Never>?
    private var settleTimer: Task<Void, Never>?
    private var lastAlDenteScan: ContinuousClock.Instant?
```

Replace `startPolling()` and `stopPolling()`:

```swift
    func startPolling() {
        polling?.cancel()
        lastAlDenteScan = nil
        polling = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: reconciler.isSettling(now: .now) ? .milliseconds(500) : .seconds(2))
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
        reconciler.closed(now: .now)
    }
```

In `refresh()`, replace from `guard helper == .enabled else {` to the end of the function with:

```swift
        guard helper == .enabled else {
            reconciler.reset()
            publish()
            daemonError = nil
            return
        }
        guard let token = reconciler.beginPoll() else { return }
        do {
            let new = try await client.send(.getStatus)
            if reconciler.received(new, for: token, now: .now) { daemonError = nil }
        } catch {
            if reconciler.failed(token, now: .now) != .stale {
                daemonError = "Helper not reachable: \(error.localizedDescription)"
            }
        }
        publish()
        pump()
    }
```

Replace `perform(_:)` and `send(_:)` with:

```swift
    /// A user click: shows the result at once and queues the request; the latest click on a control wins.
    func change(_ request: Request) {
        actionError = nil
        reconciler.want(request, now: .now)
        publish()
        pump()
    }

    /// Sends queued changes one at a time until none is left or a poll is in flight; `refresh` restarts it then.
    private func pump() {
        guard sender == nil else { return }
        sender = Task {
            while let next = reconciler.nextCommand() {
                let (request, token) = next
                do {
                    let new = try await client.send(request)
                    if reconciler.received(new, for: token, now: .now) { daemonError = nil }
                } catch {
                    switch reconciler.failed(token, now: .now) {
                    case .retry:
                        publish()
                        try? await Task.sleep(for: .seconds(1))
                    case .gaveUp:
                        actionError = "Helper not reachable — change not applied."
                    case .stale:
                        break
                    }
                }
                publish()
            }
            sender = nil
        }
    }

    /// Copies what the Reconciler shows, and wakes again at the settle deadline, when that can change on its own.
    private func publish() {
        let now = ContinuousClock.now
        let shown = reconciler.displayed(now: now)
        if shown != status { status = shown }
        waitingForHelper = reconciler.waitingForHelper
        settleTimer?.cancel()
        guard let deadline = reconciler.settleDeadline, deadline > now else { return }
        settleTimer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { publish() }
        }
    }
```

In `uninstallHelper(skipRelease:)`, replace:

```swift
        // Drop any poll reply still in flight.
        requestSeq += 1
        appliedSeq = requestSeq
        helper = HelperInstaller.status
        status = nil
```

with:

```swift
        // Drop queued changes and any reply still in flight.
        reconciler.reset()
        helper = HelperInstaller.status
        publish()
```

- [ ] **Step 3: Update `PopoverView.swift`.**

In `BatteryTile`, after the `HStack(alignment: .firstTextBaseline) { … }` that holds the percentage and `status.stateLabel`, add:

```swift
            if model.waitingForHelper {
                Text("Waiting for helper…").font(.caption).foregroundStyle(.secondary)
            }
```

Replace the slider's `onEditingChanged` closure body with:

```swift
                   onEditingChanged: { editing in
                       guard !editing, let draft = draftLimit else { return }
                       draftLimit = nil
                       if Int(draft) != status.settings.chargeLimit { model.change(.setLimit(Int(draft))) }
                   })
```

In `ControlGrid`, replace the three `Task { await model.perform(…) }` lines with sync calls:

```swift
                    model.change(current.toppingUp ? .cancelTopUp : .topUp)
```
```swift
                    model.change(.setPaused(current.state != .paused))
```
```swift
                    model.change(.setLEDMode(current.settings.ledMode.next))
```

Keep each `guard let current = model.status else { return }` line: `model.status` is now the displayed status, so a second click toggles from what is on screen.

- [ ] **Step 4: Build.**
Run: `xcodegen generate && xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug -derivedDataPath build -allowProvisioningUpdates build -quiet`
Expected: builds with no errors or new warnings. `grep -rn "perform(\|requestSeq\|appliedSeq" EnerG/` prints nothing.

- [ ] **Step 5: Run all tests.**
Run: `swift test --package-path Packages/EnerGKit`
Expected: all pass.

- [ ] **Step 6: Commit.**

```bash
git add EnerG/AppModel.swift EnerG/PopoverView.swift
git commit -m "feat: instant controls through the reconciler"
```

- [ ] **Step 7: Manual check on the device (ask the user to install with `scripts/install.sh` and try):**
  1. Pause, Top Up, LED and the Charge Limit slider each change the popover at once.
  2. Paused at or above the limit, Resume shows "Draining to N%" / "Holding at N%" at once, with no "Charging" in between.
  3. With a limit below 80, Resume then Pause again within a second: the second click takes, and the end state is Paused.
  4. Top Up, then stop it at or above the limit: no "Charging" blip.
  5. Resume and close the popover right away; reopen after ~10 s: no "Charging" flash.
  6. Stop the helper during a change (the user runs `sudo launchctl bootout system/app.energ.energd` in their own terminal): "Waiting for helper…" appears; after ~10 s the error tile reads "Helper not reachable — change not applied." and the tiles show the real state.

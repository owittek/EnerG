# Error Handling and At-Limit Charging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No false "Charging" at the limit after a limit write; the popover shows at most one friendly problem notice, with raw errors logged instead of shown.

**Architecture:** `BatterySnapshot.isCharging` treats a `CHLT` status `00` at or above the limit as not charging. A new pure `Problem` enum in EnerGCore owns all problem copy, buttons and precedence. `AppModel` maps events onto it and logs raw errors; `PopoverView` renders one `ProblemTile`.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI app (XcodeGen), macOS 27, OSLog.

Spec: `docs/superpowers/specs/2026-10-22-energ-error-handling-design.md`.

## Global Constraints

- Work on branch `footer-polish` in the main checkout (no worktree).
- Tests: `swift test --package-path Packages/EnerGKit`. Build: `xcodegen generate && xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug -derivedDataPath build -allowProvisioningUpdates build -quiet` (repo root). Every task ends with tests passing; tasks touching `EnerG/` or a public EnerGCore API also build.
- Copy, exact: "Helper not reachable." · "Helper not reachable. Your change wasn't applied." · "Waiting for helper…" (U+2026) · "Couldn't install the helper." · "Couldn't hand charging back to macOS, so the helper is still installed." · "Couldn't uninstall the helper." · "Couldn't change Launch at Login." · buttons "Uninstall Anyway", "Open Login Items". Apostrophes are U+0027.
- Logger: `Logger(subsystem: "app.energ", category: "app")`, errors with `privacy: .public`.
- Commits: repo style lower case; **never** Co-Authored-By or any AI attribution. Stage files by path. Never commit `.superpowers/`, `build/`, `EnerG.xcodeproj`. Never run sudo.
- Comments: short contract doc comments, ~120 columns, matching surrounding code.
- Keep mutating calls out of `#expect(...)`.

---

### Task 1: At-limit `00` reads as not charging

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Model.swift` (`BatterySnapshot.isCharging`)
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift` (the one call in `snapshot()`)
- Modify: `Packages/EnerGKit/Sources/energ-smoke/main.swift` (remove the temporary `watch` command: every line tagged `// [DEBUG-chlt]`)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/IsChargingTests.swift`

**Interfaces:**
- Produces: `public static func BatterySnapshot.isCharging(chlt: [UInt8]?, percent: Int, adapterConnected: Bool, registryIsCharging: Bool) -> Bool`.

- [ ] **Step 1: Update the tests.** In `IsChargingTests.swift`, change the helper and add a test:

```swift
    private func charging(_ chlt: [UInt8]?, percent: Int = 50, registry: Bool = false, plugged: Bool = true) -> Bool {
        BatterySnapshot.isCharging(chlt: chlt, percent: percent, adapterConnected: plugged, registryIsCharging: registry)
    }
```

```swift
    // Straight after a limit write the status byte reads 00 for about a second before it settles on 05.
    @Test func atOrAboveTheLimitIsNeverCharging() {
        #expect(!charging([60, 0x05, 0x00], percent: 60))
        #expect(!charging([60, 0x05, 0x00], percent: 61))
        #expect(charging([60, 0x05, 0x00], percent: 59))
    }
```

- [ ] **Step 2: Run to verify it fails.** `swift test --package-path Packages/EnerGKit --filter IsChargingTests` → compile error (extra argument `percent`).

- [ ] **Step 3: Implement.** In `Model.swift` replace `isCharging` with:

```swift
    /// Whether the battery is charging. While the native limit is on, SMC `CHLT` = `[limit, band, status]` says so
    /// live: status `00` charging, `03` Limit Drain, `05` holding. At or above the limit, `00` is the firmware's state
    /// for about a second after the limit is written, before it settles on `05`, so it reads as not charging.
    /// IOKit `IsCharging` refreshes only about every 60 s, so it is the fallback: limit off (where `00` means off),
    /// unplugged, unreadable, or an unknown status.
    public static func isCharging(chlt: [UInt8]?, percent: Int, adapterConnected: Bool,
                                  registryIsCharging: Bool) -> Bool {
        guard adapterConnected, let chlt, chlt.count == 3, chlt[0] != 0 else { return registryIsCharging }
        switch chlt[2] {
        case 0x00: return percent < Int(chlt[0])
        case 0x03, 0x05: return false
        default: return registryIsCharging
        }
    }
```

Update the `isCharging` property doc reference if needed (`/// Live from the firmware while the native limit is on; see `isCharging(chlt:percent:adapterConnected:registryIsCharging:)`.`).

In `MacHardware.snapshot()`, pass `percent: percent,` after `chlt:`.

In `energ-smoke/main.swift`, delete every line ending in `// [DEBUG-chlt]` (the whole `case ("watch", _):` block). `grep -rn "DEBUG-chlt" Packages/` must print nothing.

- [ ] **Step 4: Run all tests and build the package.** `swift test --package-path Packages/EnerGKit` → all pass; `swift build --package-path Packages/EnerGKit` → no errors.

- [ ] **Step 5: Commit.**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/Model.swift Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift \
  Packages/EnerGKit/Tests/EnerGCoreTests/IsChargingTests.swift
git commit -m "fix: a limit write no longer reads as charging at the limit"
```

(`energ-smoke/main.swift` only lost uncommitted debug lines; if `git status` shows it modified vs HEAD, stop and report.)

---

### Task 2: `Problem`

**Files:**
- Create: `Packages/EnerGKit/Sources/EnerGCore/Problem.swift`
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/ProblemTests.swift`

**Interfaces:**
- Produces: `public enum Problem: Equatable, Sendable` with cases `installFailed, releaseFailed, uninstallFailed, launchAtLoginFailed, changeNotApplied, waitingForHelper, helperUnreachable`; `public var message: String`; `public var action: ProblemAction?`; `public var isPending: Bool`; `public static func shown(failure: Problem?, connection: Problem?) -> Problem?`. `public enum ProblemAction: Equatable, Sendable { case uninstallAnyway, openLoginItems }` with `public var title: String`.

- [ ] **Step 1: Write the failing tests.** Create `ProblemTests.swift`:

```swift
import Testing
@testable import EnerGCore

struct ProblemTests {
    @Test func copy() {
        #expect(Problem.helperUnreachable.message == "Helper not reachable.")
        #expect(Problem.changeNotApplied.message == "Helper not reachable. Your change wasn't applied.")
        #expect(Problem.waitingForHelper.message == "Waiting for helper…")
        #expect(Problem.installFailed.message == "Couldn't install the helper.")
        #expect(Problem.releaseFailed.message
                == "Couldn't hand charging back to macOS, so the helper is still installed.")
        #expect(Problem.uninstallFailed.message == "Couldn't uninstall the helper.")
        #expect(Problem.launchAtLoginFailed.message == "Couldn't change Launch at Login.")
    }

    @Test func buttons() {
        #expect(Problem.releaseFailed.action == .uninstallAnyway)
        #expect(Problem.launchAtLoginFailed.action == .openLoginItems)
        #expect(ProblemAction.uninstallAnyway.title == "Uninstall Anyway")
        #expect(ProblemAction.openLoginItems.title == "Open Login Items")
        for problem in [Problem.installFailed, .uninstallFailed, .changeNotApplied, .waitingForHelper,
                        .helperUnreachable] {
            #expect(problem.action == nil)
        }
    }

    @Test func onlyWaitingIsPending() {
        #expect(Problem.waitingForHelper.isPending)
        #expect(!Problem.helperUnreachable.isPending)
        #expect(!Problem.changeNotApplied.isPending)
    }

    @Test func aFailureBeatsTheConnection() {
        #expect(Problem.shown(failure: .launchAtLoginFailed, connection: .helperUnreachable) == .launchAtLoginFailed)
        #expect(Problem.shown(failure: .changeNotApplied, connection: .helperUnreachable) == .changeNotApplied)
        #expect(Problem.shown(failure: nil, connection: .waitingForHelper) == .waitingForHelper)
        #expect(Problem.shown(failure: nil, connection: nil) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails.** `swift test --package-path Packages/EnerGKit --filter ProblemTests` → compile error, `Problem` not found.

- [ ] **Step 3: Implement.** Create `Problem.swift`:

```swift
/// Something wrong that the popover shows as its one problem notice: a click that failed, a dropped change, or the
/// connection to energd. Copy lives here, not in the app, so it is unit-tested.
public enum Problem: Equatable, Sendable {
    /// Registering the helper failed (not the normal wait for approval in Login Items).
    case installFailed
    /// `release` failed during uninstall, so the helper is still installed.
    case releaseFailed
    case uninstallFailed
    /// Turning Launch at Login on or off failed.
    case launchAtLoginFailed
    /// A change was retried for `Reconciler.retryWindow` without reaching energd, then dropped.
    case changeNotApplied
    /// A change is being retried.
    case waitingForHelper
    /// Polls can't reach energd.
    case helperUnreachable

    /// The one problem to show: a failed click or dropped change first, else the connection.
    public static func shown(failure: Problem?, connection: Problem?) -> Problem? { failure ?? connection }

    public var message: String {
        switch self {
        case .installFailed: "Couldn't install the helper."
        case .releaseFailed: "Couldn't hand charging back to macOS, so the helper is still installed."
        case .uninstallFailed: "Couldn't uninstall the helper."
        case .launchAtLoginFailed: "Couldn't change Launch at Login."
        case .changeNotApplied: "Helper not reachable. Your change wasn't applied."
        case .waitingForHelper: "Waiting for helper…"
        case .helperUnreachable: "Helper not reachable."
        }
    }

    /// The button the notice offers, if any.
    public var action: ProblemAction? {
        switch self {
        case .releaseFailed: .uninstallAnyway
        case .launchAtLoginFailed: .openLoginItems
        default: nil
        }
    }

    /// Still in progress: shown with a spinner instead of an error icon.
    public var isPending: Bool { self == .waitingForHelper }
}

/// What a problem notice's button does.
public enum ProblemAction: Equatable, Sendable {
    /// Unregister the helper without `release`.
    case uninstallAnyway
    /// Open System Settings → General → Login Items.
    case openLoginItems

    public var title: String {
        switch self {
        case .uninstallAnyway: "Uninstall Anyway"
        case .openLoginItems: "Open Login Items"
        }
    }
}
```

- [ ] **Step 4: Run all tests.** `swift test --package-path Packages/EnerGKit` → all pass.

- [ ] **Step 5: Commit.**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/Problem.swift Packages/EnerGKit/Tests/EnerGCoreTests/ProblemTests.swift
git commit -m "feat: one problem notice with friendly copy"
```

---

### Task 3: Wire `Problem` into `AppModel` and `PopoverView`

**Files:**
- Modify: `EnerG/AppModel.swift`
- Modify: `EnerG/PopoverView.swift`

**Interfaces:**
- Consumes: `Problem`, `ProblemAction` (Task 2).
- Produces: `AppModel.problem: Problem?`, `AppModel.resolve(_ action: ProblemAction)`. Removes `daemonError`, `actionError`, `offersUninstallAnyway`.

No unit tests (logic is in `Problem` and `Reconciler`); verify by building.

- [ ] **Step 1: `AppModel` state.** Add `import OSLog`. Replace the `daemonError`, `actionError` (with its `didSet`) and `offersUninstallAnyway` properties with:

```swift
    /// The one problem the popover shows, if anything is wrong.
    var problem: Problem? {
        Problem.shown(failure: failure,
                      connection: waitingForHelper ? .waitingForHelper : unreachable ? .helperUnreachable : nil)
    }
```

and, with the other private properties:

```swift
    private let log = Logger(subsystem: "app.energ", category: "app")
    /// A failed click or a dropped change; cleared when the user starts any action. A dropped change also clears once
    /// energd answers again.
    private var failure: Problem?
    /// Polls can't reach energd; cleared by an applied reply.
    private var unreachable = false
```

Add these private helpers (e.g. below `publish()`):

```swift
    /// Shows `problem` and logs the underlying error, which the popover doesn't show.
    private func fail(_ problem: Problem, _ error: any Error) {
        log.error("\(String(describing: problem), privacy: .public): \(String(describing: error), privacy: .public)")
        failure = problem
    }

    /// energd answered: it is reachable, so a dropped change no longer needs saying.
    private func reached() {
        unreachable = false
        if failure == .changeNotApplied { failure = nil }
    }
```

And a public action handler (e.g. below `setLaunchAtLogin`):

```swift
    /// Runs the button of the problem notice.
    func resolve(_ action: ProblemAction) {
        switch action {
        case .uninstallAnyway: Task { await uninstallHelper(skipRelease: true) }
        case .openLoginItems: HelperInstaller.openApproval()
        }
    }
```

- [ ] **Step 2: `AppModel` call sites.** Make exactly these replacements:
  - `init`: `actionError = "Couldn't turn on Launch at Login: \(error.localizedDescription)"` → `fail(.launchAtLoginFailed, error)`.
  - `refresh`, helper-not-enabled branch: `daemonError = nil` → `unreachable = false`.
  - `refresh`, poll reply: `if reconciler.received(new, for: token, now: .now) { daemonError = nil }` → `if reconciler.received(new, for: token, now: .now) { reached() }`.
  - `refresh`, poll catch: replace the body with:
    ```swift
            if reconciler.failed(token, now: .now) != .stale {
                unreachable = true
                log.error("status poll failed: \(String(describing: error), privacy: .public)")
            }
    ```
  - `change`: `actionError = nil` → `failure = nil`.
  - `pump`, reply: `{ daemonError = nil }` → `{ reached() }`.
  - `pump`, catch: first line of the catch block add `log.error("\(String(describing: request), privacy: .public) failed: \(String(describing: error), privacy: .public)")`; `.gaveUp` case: `actionError = "Helper not reachable — change not applied."` → `failure = .changeNotApplied`.
  - `installHelper`: `actionError = nil` → `failure = nil`; `actionError = "Install failed: \(error.localizedDescription)"` → `fail(.installFailed, error)`.
  - `uninstallHelper`: `actionError = nil` → `failure = nil`; the four-line release message plus `offersUninstallAnyway = true` → `fail(.releaseFailed, error)`; after a successful unregister `daemonError = nil` → `unreachable = false`; `actionError = "Uninstall failed: \(error.localizedDescription)"` → `fail(.uninstallFailed, error)`.
  - `setLaunchAtLogin`: `actionError = nil` → `failure = nil`; `catch { actionError = error.localizedDescription }` → `catch { fail(.launchAtLoginFailed, error) }`.

Update the `uninstallHelper` doc comment only if it mentions the removed properties. `grep -n "daemonError\|actionError\|offersUninstallAnyway" EnerG/` must print nothing at the end of Step 3.

- [ ] **Step 3: `PopoverView`.**
  - In `PopoverView.body`, the no-status branch: `} else if model.daemonError != nil || model.actionError != nil {` → `} else if model.problem != nil {`, and both `ErrorTiles(model: model)` calls → `ProblemTile(model: model)`. In `NoticeTiles`, `ErrorTiles(model: model)` → `ProblemTile(model: model)`.
  - In `BatteryTile`, delete the `if model.waitingForHelper { Text("Waiting for helper…")… }` block.
  - In `NoticeTile`, add `var busy = false` after `tint`, document it (`/// In progress: a spinner instead of the symbol, and secondary text.`), give the text `.foregroundStyle(busy ? .secondary : .primary)`, and make the icon:
    ```swift
        } icon: {
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
    ```
  - Replace `ErrorTiles` with:
    ```swift
    /// The one problem, if any: a spinner while a change is retried, else an error with its button.
    private struct ProblemTile: View {
        let model: AppModel

        var body: some View {
            if let problem = model.problem {
                NoticeTile(text: problem.message, symbol: "xmark.octagon.fill", tint: .red, busy: problem.isPending,
                           actionTitle: problem.action?.title) {
                    if let action = problem.action { model.resolve(action) }
                }
            }
        }
    }
    ```

- [ ] **Step 4: Build and test.** Run the build and `swift test --package-path Packages/EnerGKit`; both pass with no new warnings.

- [ ] **Step 5: Commit.**

```bash
git add EnerG/AppModel.swift EnerG/PopoverView.swift
git commit -m "feat: show one problem notice and log the raw error"
```

- [ ] **Step 6: Manual check (user):** reinstall with `scripts/install.sh`. Resume and Stop Top Up at the limit show no "Charging". With the helper stopped during a change: one "Waiting for helper…" notice with a spinner below the battery tile, then one "Helper not reachable. Your change wasn't applied."

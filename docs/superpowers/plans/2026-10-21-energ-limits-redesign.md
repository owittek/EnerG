# EnerG Limits Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- Charge Limits from 50 to 100 %.
- Discharge and Auto-Discharge removed.
- A Limit Drain state, and a Weak Adapter rule that excludes it.

Spec: `docs/superpowers/specs/2026-10-21-energ-limits-redesign-design.md`. Decision: `docs/adr/0001-sub-80-limits-via-smartcharging-override.md`.

**Architecture:**
- **Engine/Policy (EnerGCore):** lose all adapter and sleep bookkeeping. They track an *effective* limit, which is what the hardware reports in effect.
- **Native Limit (new module in EnerGCore, behind a `LimitControls` port):** owns the sub-80 sequence: PowerUI → defaults override → notify → verify `CHLT` → `CHIE` pulse → fallback to 80. It is unit-tested with `FakeLimitControls`.
- **`MacHardware`:** provides the primitives and delegates `setChargeLimit` to `NativeLimit`.

**Tech Stack:**
- Swift 6 and Swift Testing.
- SwiftPM package `Packages/EnerGKit`.
- XcodeGen + xcodebuild for `EnerG.app` / `energd`.
- AppleSMC through `CPlatform`.
- PowerUI (private) and CFPreferences.

## Global Constraints

- **Platform:** macOS 27, Apple Silicon. `SWIFT_VERSION` is `"6.0"`.
- **Core tests:** `swift test --package-path Packages/EnerGKit`, run from the repo root. They must all pass at the end of every task.
- **App build check:** `xcodegen generate && xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug -derivedDataPath build -allowProvisioningUpdates build 2>&1 | grep -E "error:|warning: .*EnerG|BUILD (SUCCEEDED|FAILED)"`. Expected: `** BUILD SUCCEEDED **`. Run it at the end of every task that touches `EnerG/`, `energd/` or a type they use.
- **Commits:** never add `Co-Authored-By` or any Claude/AI attribution to a commit message.
- **`.superpowers/`** is gitignored and never committed.
- **`sudo`:** the agent never runs `sudo`. The user runs root steps in their own terminal; `!` in the prompt can't prompt for a password. The agent reads state unprivileged (`Packages/EnerGKit/.build/debug/energ-smoke status`, `pmset -g batt`, the SMC probe from Task 1).
- **Style:** match the surrounding code, including comment density and the doc-comment style. Domain terms come from `CONTEXT.md`: Charge Limit, Limit Drain, Top Up, LED Mode, Pause, Weak Adapter. "Discharge" no longer exists as an EnerG concept.
- **Copy:** percentages are written without a space, as the app already does (`"80%"`).
- **FakeHardware** lives in `Packages/EnerGKit/Tests/EnerGCoreTests/FakeHardware.swift`. `started(settings) { configure }` returns an Engine that has handled `.start`, with the writes cleared. Its default snapshot is 70 %, charging, plugged in, 20 W into the battery.
- **Deviation from the spec, on purpose:** the spec puts the `CHIE` check in `MacHardware.init`. This plan puts it in a `MacHardware.recoverAdapter()` that energd calls once before `.start`. That way `energ-smoke` (which also creates a `MacHardware`) doesn't silently undo an `adapter off`.

---

### Task 1: Device spike — pulse above a new lower limit at a steady %

Spec "Verification" 1. This task gates the plan.
- **Clean outcome:** continue. NativeLimit needs no stuck recovery.
- **Stuck outcome:** **stop the plan** and report to the user; the design needs revisiting.

No code changes in the repo.

**Files:**
- Create (scratch, not committed): `<your scratchpad>/probe.c`
- Modify (only the outcome line): `docs/superpowers/specs/2026-10-20-energ-design.md`, in "Verified platform facts"

**Interfaces:**
- Consumes: nothing.
- Produces: the facts line in the base spec. Task 3 relies on its outcome being "clean".

- [ ] **Step 1: Build the unprivileged SMC probe** in your scratchpad directory. Don't add it to the repo.

```c
#include <stdio.h>
#include <string.h>
#include "CPlatform.h"
int main(int argc, char **argv) {
  io_connect_t c; if (smc_open(&c)) { printf("open failed\n"); return 1; }
  for (int i = 1; i < argc; i++) {
    uint8_t b[32] = {0}, r = 0; uint32_t n = 32;
    kern_return_t k = smc_read(c, argv[i], b, &n, &r);
    if (k || r) { printf("%s=ERR(%d/%d) ", argv[i], k, r); continue; }
    printf("%s=", argv[i]);
    for (uint32_t j = 0; j < n && j < 8; j++) printf("%02x", b[j]);
    if (n == 2) printf("(%d)", (int16_t)(b[0] | b[1] << 8));
    printf(" ");
  }
  printf("\n"); smc_close(c); return 0;
}
```

Build from the repo root: `clang -I Packages/EnerGKit/Sources/CPlatform/include <scratch>/probe.c Packages/EnerGKit/Sources/CPlatform/smc.c -framework IOKit -framework CoreFoundation -o <scratch>/probe`.

Check: `<scratch>/probe CHIE CHLT B0AC AC-W` prints four values.
- `CHLT` is `[limit, 05, status]`.
- The status byte reads `03` during a Limit Drain and `05` while holding.

- [ ] **Step 2: Ask the user to set up a steady hold just below the current %.**
  - Preconditions: EnerG paused, AlDente quit, charger plugged in. Also build energ-smoke: `swift build --package-path Packages/EnerGKit --product energ-smoke`.
  - Read the current %: `Packages/EnerGKit/.build/debug/energ-smoke status`. Call it P. Let H = P rounded down to a whole number, and the new lower value N = H − 4.
  - The user runs, in their own terminal (fish: `set E …` instead of `E=…`):

```
E=/Users/oli/code/energ/Packages/EnerGKit/.build/debug/energ-smoke
sudo $E limit 80
sudo defaults write com.apple.smartcharging.topoffprotection mclLimitValue -int <H>
notifyutil -p com.apple.smartcharging.defaultschanged
sudo $E adapter off; sleep 1; sudo $E adapter on
```

  - Check with the probe every 5 s until `CHLT` = `<H hex>0505` and `B0AC` ≈ 0. That's a steady hold at H.

- [ ] **Step 3: Lower the value without a trigger.**
  - The user runs:

```
sudo defaults write com.apple.smartcharging.topoffprotection mclLimitValue -int <N>
notifyutil -p com.apple.smartcharging.defaultschanged
```

  - Probe every 10 s for 60 s. Expected: `CHLT[0]` stays H, because the % is steady. If it changes to N on its own, note "notify applied at a steady %" and go to Step 5.

- [ ] **Step 4: Pulse, and watch for the stuck state.**
  - Start this sampler first, then have the user run the pulse line:

```bash
for i in $(seq 1 20); do echo "$(date +%T) $(pmset -g batt | head -1 | cut -d"'" -f2) $(<scratch>/probe CHIE CHLT B0AC)"; sleep 1; done
```

  - The user runs: `sudo $E adapter off; sleep 1; sudo $E adapter on`.
  - **Clean:** `CHLT[0]` = N, and "AC Power" returns within 2 s of `CHIE`=00. `B0AC` < 0 follows, which is the Limit Drain toward N.
  - **Stuck:** "Battery Power" persists for more than 5 s after `CHIE`=00.

- [ ] **Step 5: Record the outcome and restore.**
  - Add one bullet to `docs/superpowers/specs/2026-10-20-energ-design.md` under "Verified platform facts", after the "Live battery power" bullet:
    - Clean: `- **Sub-80 pulse above the new limit (2026-10-21, Mac17,8):** at a steady % the override isn't applied on notify alone; a CHIE pulse (08, ~1 s, 00) applies it, and "AC Power" returns within 2 s. No stuck state.`
    - Stuck or another result: write what you saw, in the same format.
  - The user resumes EnerG, or runs `sudo $E limit 80`.
  - Commit:

```bash
git add docs/superpowers/specs/2026-10-20-energ-design.md
git commit -m "docs: record sub-80 pulse spike outcome"
```

  - If the outcome is **stuck**, stop here and report to the user.

---

### Task 2: Remove Discharge and Auto-Discharge

Spec: Engine/Policy "Removed", Model/protocol, energd, and App (tile removal only).

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Model.swift`, `Protocol.swift`, `Hardware.swift`, `Policy.swift`, `Engine.swift`
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift`, `Packages/EnerGKit/Sources/energ-smoke/main.swift`, `scripts/smoke.sh`
- Modify: `energd/SystemEvents.swift`, `energd/EngineHost.swift`
- Modify: `EnerG/PopoverView.swift`, `EnerG/AppModel.swift`
- Delete: `Packages/EnerGKit/Tests/EnerGCoreTests/DischargeTests.swift`
- Rewrite: `Packages/EnerGKit/Tests/EnerGCoreTests/FakeHardware.swift`, `EngineBasicsTests.swift`, `TopUpAndWarningsTests.swift`, `ProtocolTests.swift`, `SettingsStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `protocol Hardware { func snapshot() throws -> BatterySnapshot; func setChargeLimit(_ percent: Int?) throws; func setLED(_ state: LEDState) throws }`.
  - `Settings(chargeLimit:ledMode:paused:)`.
  - `LEDMode { auto, off }`, `LEDState { system, off, green, orange }`, `Feature { chargeLimit, led }`.
  - `ChargeState { charging, atLimit, toppingUp, paused, onBattery, unknown }`.
  - `Request { getStatus, setLimit, topUp, cancelTopUp, setLEDMode, setPaused, release }`.
  - `Status(state:settings:snapshot:toppingUp:warnings:)`.
  - `Event { start, tick, powerChanged, didWake, command, stop }`.
  - `Session { toppingUp, weakSamples, unavailable, released }`.
  - `Actuation { chargeLimit, led }`.
  - `Policy.update(settings:snapshot:countsWeakSample:session:)`.
  - FakeHardware `Write { limit(Int?), led(LEDState) }`.

- [ ] **Step 1: Rewrite the tests to the new model (they will fail to compile).**

`git rm Packages/EnerGKit/Tests/EnerGCoreTests/DischargeTests.swift`

`FakeHardware.swift`:

```swift
@testable import EnerGCore

/// Records writes; tests set `snap` to simulate the battery.
final class FakeHardware: Hardware {
    enum Write: Equatable {
        case limit(Int?), led(LEDState)
    }

    var snap = BatterySnapshot(percent: 70, isCharging: true, adapterConnected: true,
                               adapterWatts: 96, batteryWatts: 20, systemWatts: 15)
    var writes: [Write] = []
    var failing: Set<Feature> = []
    /// Non-nil limits whose write throws; disabling the limit still succeeds.
    var failingLimits: Set<Int> = []
    var snapshotFails = false

    func snapshot() throws -> BatterySnapshot {
        if snapshotFails { throw HardwareError.io(-1) }
        return snap
    }

    func setChargeLimit(_ percent: Int?) throws {
        if failing.contains(.chargeLimit) { throw HardwareError.notPrivileged }
        if let percent, failingLimits.contains(percent) { throw HardwareError.io(-2) }
        writes.append(.limit(percent))
    }

    func setLED(_ state: LEDState) throws {
        if failing.contains(.led) { throw HardwareError.notPrivileged }
        writes.append(.led(state))
    }
}

/// An Engine that has handled `.start`, with the start writes cleared.
func started(_ settings: Settings = Settings(),
             _ configure: (FakeHardware) -> Void = { _ in }) -> (Engine, FakeHardware) {
    let hw = FakeHardware()
    configure(hw)
    let engine = Engine(hardware: hw, settings: settings)
    engine.handle(.start)
    hw.writes.removeAll()
    return (engine, hw)
}
```

`EngineBasicsTests.swift`:

```swift
import Testing
@testable import EnerGCore

struct EngineBasicsTests {
    @Test func startAppliesEverything() {
        let hw = FakeHardware()
        let engine = Engine(hardware: hw, settings: Settings())
        let status = engine.handle(.start)
        #expect(hw.writes == [.limit(80), .led(.orange)])
        #expect(status.state == .charging)
        #expect(status.warnings.isEmpty)
    }

    @Test func repeatedEventsWriteNothing() {
        let (engine, hw) = started()
        engine.handle(.tick)
        engine.handle(.powerChanged)
        engine.handle(.command(.getStatus))
        #expect(hw.writes.isEmpty)
    }

    @Test func pluggedInNotChargingIsAtLimitWithGreenLED() {
        let (engine, hw) = started()
        hw.snap.percent = 80
        hw.snap.isCharging = false
        let status = engine.handle(.tick)
        #expect(hw.writes == [.led(.green)])
        #expect(status.state == .atLimit)
    }

    @Test func setLimitAcceptsOnlyAllowedValues() {
        let (engine, hw) = started()
        var status = engine.handle(.command(.setLimit(90)))
        #expect(hw.writes == [.limit(90)])
        #expect(status.settings.chargeLimit == 90)
        hw.writes.removeAll()
        status = engine.handle(.command(.setLimit(87)))
        #expect(hw.writes.isEmpty)
        #expect(status.settings.chargeLimit == 90)
    }

    @Test func limit100DisablesNativeLimit() {
        let (engine, hw) = started()
        engine.handle(.command(.setLimit(100)))
        #expect(hw.writes == [.limit(nil)])
    }

    @Test func pauseReleasesEverythingAndResumeReapplies() {
        let (engine, hw) = started()
        var status = engine.handle(.command(.setPaused(true)))
        #expect(hw.writes == [.limit(nil), .led(.system)])
        #expect(status.state == .paused)
        #expect(engine.settings.paused)
        hw.writes.removeAll()
        status = engine.handle(.command(.setPaused(false)))
        #expect(hw.writes == [.limit(80), .led(.orange)])
        #expect(status.state == .charging)
    }

    @Test func releaseIsPause() {
        let (engine, hw) = started()
        let status = engine.handle(.command(.release))
        #expect(hw.writes == [.limit(nil), .led(.system)])
        #expect(status.state == .paused)
    }

    @Test func releaseIsNotPersisted() {
        let (engine, hw) = started()
        engine.handle(.command(.release))
        #expect(engine.settings.paused == false)
        hw.writes.removeAll()
        #expect(engine.handle(.command(.topUp)).state == .paused)   // released acts exactly like paused
        #expect(hw.writes.isEmpty)

        // Reinstall: a new energd starts from the same settings and is not paused.
        let hw2 = FakeHardware()
        let restarted = Engine(hardware: hw2, settings: engine.settings)
        let status = restarted.handle(.start)
        #expect(status.state == .charging)
        #expect(hw2.writes == [.limit(80), .led(.orange)])
    }

    @Test func resumeAfterReleaseReapplies() {
        let (engine, hw) = started()
        engine.handle(.command(.release))
        hw.writes.removeAll()
        let status = engine.handle(.command(.setPaused(false)))
        #expect(status.state == .charging)
        #expect(hw.writes == [.limit(80), .led(.orange)])
    }

    @Test func unpluggedHandsLEDToSystem() {
        let (engine, hw) = started()
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        hw.snap.batteryWatts = -10
        let status = engine.handle(.powerChanged)
        #expect(hw.writes == [.led(.system)])
        #expect(status.state == .onBattery)
        #expect(!status.warnings.contains(.weakAdapter))
    }

    @Test func ledModeOffAndBack() {
        let (engine, hw) = started()
        engine.handle(.command(.setLEDMode(.off)))
        #expect(hw.writes == [.led(.off)])
        hw.writes.removeAll()
        engine.handle(.command(.setLEDMode(.auto)))
        #expect(hw.writes == [.led(.orange)])
    }

    @Test func unreadableBatteryWritesNothingAndWarns() {
        let (engine, hw) = started()
        hw.snapshotFails = true
        let status = engine.handle(.tick)
        #expect(hw.writes.isEmpty)
        #expect(status.state == .unknown)
        #expect(status.snapshot == nil)
        #expect(status.warnings.contains(.batteryUnreadable))
    }

    @Test func startWithUnreadableBatteryWritesNothing() {
        let hw = FakeHardware()
        hw.snapshotFails = true
        let engine = Engine(hardware: hw, settings: Settings())
        let status = engine.handle(.start)
        #expect(hw.writes.isEmpty)
        #expect(status.state == .unknown)
        #expect(status.warnings.contains(.batteryUnreadable))
    }

    @Test func pauseAppliesEvenWhenBatteryUnreadable() {
        let (engine, hw) = started()
        hw.snapshotFails = true
        let status = engine.handle(.command(.setPaused(true)))
        #expect(hw.writes == [.limit(nil), .led(.system)])
        #expect(status.state == .paused)
    }

    @Test func wakeReassertsFullState() {
        let (engine, hw) = started()
        engine.handle(.didWake)
        #expect(hw.writes == [.limit(80), .led(.orange)])
    }

    @Test func failedWriteDuringWakeIsRetriedNotLatched() {
        let (engine, hw) = started()
        hw.failing = [.led]
        let status = engine.handle(.didWake)
        #expect(!status.warnings.contains(.unavailable(.led)))
        #expect(hw.writes == [.limit(80)])

        hw.failing = []
        hw.writes.removeAll()
        engine.handle(.tick)   // wake re-assert incomplete: the next event re-asserts everything
        #expect(hw.writes == [.limit(80), .led(.orange)])
    }

    @Test func stopHandsLEDToSystem() {
        let (engine, hw) = started()
        engine.handle(.stop)
        // The native Charge Limit is left alone.
        #expect(hw.writes == [.led(.system)])
        #expect(engine.settings == Settings())
    }
}
```

`TopUpAndWarningsTests.swift`:

```swift
import Testing
@testable import EnerGCore

struct TopUpAndWarningsTests {
    @Test func topUpLiftsLimitUntilUnplug() {
        let (engine, hw) = started()
        var status = engine.handle(.command(.topUp))
        #expect(hw.writes == [.limit(nil)])
        #expect(status.state == .toppingUp)

        hw.writes.removeAll()
        hw.snap.adapterConnected = false
        hw.snap.isCharging = false
        status = engine.handle(.powerChanged)
        #expect(hw.writes == [.limit(80), .led(.system)])
        #expect(status.state == .onBattery)
    }

    @Test func cancelTopUpRestoresLimit() {
        let (engine, hw) = started()
        engine.handle(.command(.topUp))
        hw.writes.removeAll()
        let status = engine.handle(.command(.cancelTopUp))
        #expect(hw.writes == [.limit(80)])
        #expect(status.state == .charging)
    }

    @Test func statusReportsTopUpEvenWhenBatteryUnreadable() {
        let (engine, hw) = started()
        #expect(engine.handle(.command(.topUp)).toppingUp)
        hw.snapshotFails = true
        let status = engine.handle(.tick)
        #expect(status.state == .unknown)
        #expect(status.toppingUp)
        hw.snapshotFails = false
        #expect(!engine.handle(.command(.cancelTopUp)).toppingUp)
    }

    @Test func pausedIgnoresTopUp() {
        let (engine, hw) = started(Settings(paused: true))
        engine.handle(.command(.topUp))
        let status = engine.handle(.tick)
        #expect(hw.writes.isEmpty)
        #expect(status.state == .paused)
        #expect(!status.toppingUp)
    }

    @Test func weakAdapterNeedsTwoConsecutiveDrainingSamples() {
        let (engine, hw) = started()
        hw.snap.batteryWatts = -5
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))
        #expect(engine.handle(.tick).warnings.contains(.weakAdapter))
        hw.snap.batteryWatts = 3
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))
    }

    @Test func weakAdapterCountsOnlyTicks() {
        let (engine, hw) = started()
        hw.snap.batteryWatts = -5
        engine.handle(.tick)
        #expect(!engine.handle(.command(.getStatus)).warnings.contains(.weakAdapter))
        #expect(!engine.handle(.didWake).warnings.contains(.weakAdapter))
        #expect(!engine.handle(.powerChanged).warnings.contains(.weakAdapter))
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

    @Test func failedLEDWriteDisablesOnlyLED() {
        let (engine, hw) = started { $0.failing = [.led] }
        var status = engine.handle(.command(.setLEDMode(.off)))
        #expect(hw.writes.isEmpty)
        #expect(status.warnings == [.unavailable(.led)])
        status = engine.handle(.command(.setLimit(90)))
        #expect(hw.writes == [.limit(90)])
    }

    @Test func failedLimitWriteDisablesOnlyChargeLimit() {
        let (engine, hw) = started { $0.failing = [.chargeLimit] }
        let status = engine.handle(.command(.setLimit(90)))
        #expect(hw.writes.isEmpty)
        #expect(status.warnings == [.unavailable(.chargeLimit)])
        hw.snap.isCharging = false
        engine.handle(.tick)
        #expect(hw.writes == [.led(.green)])
    }

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

    @Test func latchedFeatureIsNotRetriedEvenOnWake() {
        let (engine, hw) = started { $0.failing = [.led] }
        hw.failing = []
        engine.handle(.command(.setLEDMode(.off)))
        engine.handle(.didWake)
        #expect(!hw.writes.contains { if case .led = $0 { true } else { false } })
        #expect(engine.handle(.tick).warnings.contains(.unavailable(.led)))
    }
}
```

`ProtocolTests.swift`: replace the `arguments:` list and the last two tests. `snapshotWithoutPlugSensedDecodes` stays.

```swift
    @Test(arguments: [
        Request.getStatus, .setLimit(85), .topUp, .cancelTopUp, .setLEDMode(.off), .setPaused(true), .release,
    ])
```

```swift
    @Test func statusRoundTrips() throws {
        let status = Status(
            state: .atLimit,
            settings: Settings(chargeLimit: 90, ledMode: .off, paused: false),
            snapshot: BatterySnapshot(percent: 93, isCharging: false, adapterConnected: false,
                                      adapterWatts: 96, batteryWatts: -12.5, systemWatts: nil),
            toppingUp: true,
            warnings: [.weakAdapter, .unavailable(.led), .batteryUnreadable]
        )
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(Status.self, from: data) == status)
    }

    @Test func defaultSettings() {
        #expect(Settings() == Settings(chargeLimit: 80, ledMode: .auto, paused: false))
        #expect(Settings.allowedLimits == [80, 85, 90, 95, 100])
    }
```

`SettingsStoreTests.swift`: replace the tests after `missingFileLoadsDefaults` with:

```swift
    @Test func saveThenLoadRoundTrips() throws {
        let store = SettingsStore(url: url)
        let settings = Settings(chargeLimit: 95, ledMode: .off, paused: true)
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func disallowedChargeLimitLoadsDefaultLimit() throws {
        let store = SettingsStore(url: url)
        try store.save(Settings(chargeLimit: 87, ledMode: .off, paused: true))
        #expect(store.load() == Settings(chargeLimit: 80, ledMode: .off, paused: true))
    }

    @Test func corruptFileLoadsDefaults() throws {
        try write("not json")
        #expect(SettingsStore(url: url).load() == Settings())
    }

    @Test func missingFieldDefaultsOnlyThatField() throws {
        try write(#"{"chargeLimit":90,"paused":true}"#)
        #expect(SettingsStore(url: url).load() == Settings(chargeLimit: 90, ledMode: .auto, paused: true))
    }

    @Test func invalidFieldDefaultsOnlyThatField() throws {
        try write(#"{"chargeLimit":90,"ledMode":"rainbow","paused":true}"#)
        #expect(SettingsStore(url: url).load() == Settings(chargeLimit: 90, ledMode: .auto, paused: true))
    }

    // A settings file from a build with Discharge: the old key is ignored, Blink falls back to Auto.
    @Test func settingsFromDischargeBuildLoad() throws {
        try write(#"{"chargeLimit":90,"autoDischarge":false,"ledMode":"blink","paused":true}"#)
        #expect(SettingsStore(url: url).load() == Settings(chargeLimit: 90, ledMode: .auto, paused: true))
    }
```

- [ ] **Step 2: Run tests to verify they fail.** Run `swift test --package-path Packages/EnerGKit`. Expected: compile errors, e.g. `Settings` has no `init(chargeLimit:ledMode:paused:)` and `FakeHardware` doesn't conform to `Hardware`.

- [ ] **Step 3: Shrink the model and protocol.**

`Model.swift`:
- `Settings`:
  - Remove `autoDischarge` (property, `init` parameter, decoder line).
  - `init(chargeLimit: Int = 80, ledMode: LEDMode = .auto, paused: Bool = false)`.
  - Leave `allowedLimits` alone; Task 4 changes it.
- `LEDMode` becomes:

```swift
/// How EnerG drives the MagSafe LED.
public enum LEDMode: String, Codable, Sendable, CaseIterable {
    /// Orange while charging, green otherwise while plugged in.
    case auto
    /// Always off (while not paused and plugged in).
    case off
}
```

- `LEDState`: `case system, off, green, orange`.
- `Feature`: `case chargeLimit, led`.
- `ChargeState`: `case charging, atLimit, toppingUp, paused, onBattery, unknown`.
- `BatterySnapshot.adapterConnected` doc: replace "Stays true while EnerG cuts the adapter for a Discharge and while" with "Stays true while EnerG pulses the adapter and while". Its `plugSensed` doc: replace "so it stays true while EnerG cuts the adapter" with "so it stays true while `CHIE` cuts the adapter".

`Protocol.swift`:
- `Request`: delete `discharge(to:)`, `cancelDischarge` and `setAutoDischarge(Bool)`.
- `Status`: delete `dischargeTarget` (property, doc, `init` parameter and assignment).
- New init: `public init(state: ChargeState, settings: Settings, snapshot: BatterySnapshot?, toppingUp: Bool, warnings: [Warning])`.

`Hardware.swift`, the protocol becomes:

```swift
/// Everything the Engine needs from the machine. Writes may throw; the Engine
/// then marks the matching `Feature` unavailable and stops writing it.
public protocol Hardware: AnyObject {
    func snapshot() throws -> BatterySnapshot
    /// Sets the native Charge Limit; nil disables it.
    func setChargeLimit(_ percent: Int?) throws
    func setLED(_ state: LEDState) throws
}
```

- [ ] **Step 4: Rewrite `Policy.swift`.**

```swift
/// Runtime state the Engine keeps between events (not persisted).
struct Session: Equatable {
    var toppingUp = false
    var weakSamples = 0
    var unavailable: Set<Feature> = []
    /// Set by `.release` (before uninstall): acts exactly like Pause but is never persisted, so a
    /// reinstall starts with the user's real settings. Cleared by `setPaused` and `.start`.
    var released = false
}

/// What the hardware should look like right now.
struct Actuation: Equatable {
    var chargeLimit: Int?
    var led: LEDState

    /// Stock macOS behaviour: used for Pause and release.
    static let released = Actuation(chargeLimit: nil, led: .system)
}

enum Policy {
    /// Pause, or released before uninstall.
    static func isPaused(_ settings: Settings, _ s: Session) -> Bool { settings.paused || s.released }

    /// Pause drops every running mode.
    static func clearForPause(_ s: inout Session) {
        s.toppingUp = false
        s.weakSamples = 0
    }

    /// Advances the session for a fresh snapshot: ends a Top Up on unplug and tracks Weak Adapter samples.
    /// `countsWeakSample`: only ticks count towards a Weak Adapter; other events can only reset the count.
    static func update(settings: Settings, snapshot: BatterySnapshot, countsWeakSample: Bool, session s: inout Session) {
        if isPaused(settings, s) {
            clearForPause(&s)
            return
        }
        if !snapshot.adapterConnected { s.toppingUp = false }
        let weak = snapshot.adapterConnected && snapshot.batteryWatts < 0
        if !weak {
            s.weakSamples = 0
        } else if countsWeakSample {
            s.weakSamples += 1
        }
    }

    /// Derives the desired hardware state; no side effects.
    static func actuation(settings: Settings, snapshot: BatterySnapshot, session s: Session) -> Actuation {
        if isPaused(settings, s) { return .released }
        let limit: Int? = (s.toppingUp || settings.chargeLimit >= 100) ? nil : settings.chargeLimit
        return Actuation(chargeLimit: limit, led: led(settings.ledMode, snapshot))
    }

    private static func led(_ mode: LEDMode, _ snapshot: BatterySnapshot) -> LEDState {
        if !snapshot.adapterConnected { return .system }
        if mode == .off { return .off }
        return snapshot.isCharging ? .orange : .green
    }
}
```

- [ ] **Step 5: Rewrite `Engine.swift`.**

```swift
public enum Event: Equatable, Sendable {
    /// Daemon launch: re-applies all state.
    case start
    case tick
    case powerChanged
    case didWake
    case command(Request)
    /// Daemon shutdown: hands the LED to the system. Leaves the native Charge Limit and settings untouched.
    /// Send nothing after it except `.start`.
    case stop
}

/// Owns every charging rule. Feed it events; it writes only what changed through `Hardware`.
/// Not thread-safe: call from one serial context.
public final class Engine {
    public private(set) var settings: Settings
    private let hardware: any Hardware
    private var session = Session()
    /// Last actuation written; nil means unknown, so everything is written.
    private var applied: Actuation?
    private var snapshot: BatterySnapshot?
    /// Set while `.didWake` re-asserts the full state: a failed write is retried, not marked unavailable.
    private var wakeReassert = false
    /// A write failed during the wake re-assert; the next event re-asserts everything again.
    private var wakeReassertFailed = false

    public init(hardware: any Hardware, settings: Settings) {
        self.hardware = hardware
        self.settings = settings
    }

    @discardableResult
    public func handle(_ event: Event) -> Status {
        switch event {
        case .start:
            session = Session()
            applied = nil
        case .tick, .powerChanged:
            break
        case .stop:
            stop()
            return status()
        case .didWake:
            applied = nil   // hardware state after sleep is unknown: re-assert all of it
            wakeReassert = true
        case .command(let request):
            perform(request)
        }
        evaluate(countsWeakSample: event == .tick)
        wakeReassert = false
        return status()
    }

    private func perform(_ request: Request) {
        switch request {
        case .getStatus:
            break
        case .setLimit(let limit):
            if Settings.allowedLimits.contains(limit) { settings.chargeLimit = limit }
        case .topUp:
            guard !paused else { return }
            session.toppingUp = true
        case .cancelTopUp:
            session.toppingUp = false
        case .setLEDMode(let mode):
            settings.ledMode = mode
        case .setPaused(let paused):
            settings.paused = paused
            session.released = false
        case .release:
            session.released = true   // not persisted: a reinstall must not start paused
        }
    }

    /// Pause, or released before uninstall.
    private var paused: Bool { Policy.isPaused(settings, session) }

    private func evaluate(countsWeakSample: Bool) {
        do {
            snapshot = try hardware.snapshot()
        } catch {
            // Can't see the battery: Pause still clears every running mode and hands back; otherwise keep everything as is.
            snapshot = nil
            if paused {
                Policy.clearForPause(&session)
                apply(.released)
            }
            return
        }
        let current = snapshot!
        Policy.update(settings: settings, snapshot: current, countsWeakSample: countsWeakSample, session: &session)
        apply(Policy.actuation(settings: settings, snapshot: current, session: session))
    }

    private func apply(_ next: Actuation) {
        if changed(\.chargeLimit, to: next) { write(.chargeLimit) { try hardware.setChargeLimit(next.chargeLimit) } }
        if changed(\.led, to: next) { write(.led) { try hardware.setLED(next.led) } }
        applied = next
        if wakeReassertFailed {
            applied = nil
            wakeReassertFailed = false
        }
    }

    /// A kickstart can't be told apart from a bootout, so the native Charge Limit stays as is.
    private func stop() {
        if applied?.led != .system { write(.led) { try hardware.setLED(.system) } }
        applied?.led = .system
    }

    private func changed<T: Equatable>(_ field: KeyPath<Actuation, T>, to next: Actuation) -> Bool {
        applied.map { $0[keyPath: field] != next[keyPath: field] } ?? true
    }

    /// Runs a hardware write unless the feature is already unavailable; a failure makes it unavailable,
    /// except during the wake re-assert, where it is retried on the next event.
    private func write(_ feature: Feature, _ operation: () throws -> Void) {
        guard !session.unavailable.contains(feature) else { return }
        do {
            try operation()
        } catch {
            if wakeReassert {
                wakeReassertFailed = true
            } else {
                session.unavailable.insert(feature)
            }
        }
    }

    private func status() -> Status {
        var warnings: [Warning] = []
        if session.weakSamples >= 2 { warnings.append(.weakAdapter) }
        warnings += Feature.allCases.filter(session.unavailable.contains).map(Warning.unavailable)
        if snapshot == nil { warnings.append(.batteryUnreadable) }
        return Status(state: state(), settings: settings, snapshot: snapshot,
                      toppingUp: session.toppingUp, warnings: warnings)
    }

    private func state() -> ChargeState {
        if paused { return .paused }
        guard let snapshot else { return .unknown }
        if session.toppingUp { return .toppingUp }
        if !snapshot.adapterConnected { return .onBattery }
        return snapshot.isCharging ? .charging : .atLimit
    }
}
```

- [ ] **Step 6: Run the core tests.** Run `swift test --package-path Packages/EnerGKit`. Expected: all pass.

- [ ] **Step 7: Fix `MacHardware` and `energ-smoke`.**

`MacHardware.swift`:
- Delete `import IOKit.pwr_mgt`, the `sleepAssertion` property, the `IOPMAssertionRelease` line in `deinit`, and `setPreventSleep(_:)`.
- In `setLED`, delete `case .blinkSlow: 0x06`.
- Keep `public func setAdapter(enabled:)`. It is no longer a `Hardware` requirement, but energ-smoke uses it and Task 6 makes it a `LimitControls` requirement.
- Header doc: change "(CHIE adapter cut, ACLC LED, …)" to "(CHIE adapter pulse, ACLC LED, …)".

`energ-smoke/main.swift`: in `usage`, change `led system|off|green|orange|blinkSlow` to `led system|off|green|orange`.

`scripts/smoke.sh`: change `for led in off green orange blinkSlow system; do` to `for led in off green orange system; do`.

- [ ] **Step 8: Fix energd.**

`energd/SystemEvents.swift`:
- Delete `messageClamshellStateChange`, `lidNotifier` and the whole "Lid (clamshell) changes" block in `start()`: from `let rootDomain = …` through `host.handle(.lid(closed: closed))`.
- Class doc: "Feeds power-source, sleep/wake and timer events into the EngineHost."
- `start()` doc: "Returns false, after logging a fault, if sleep/wake notifications can't be registered; the caller must then stop and exit."
- In `power(_:_:)`, `messageSystemWillSleep` becomes just `IOAllowPowerChange(rootPort, Int(bitPattern: argument))`. Merge it with the `messageCanSystemSleep` case: `case messageCanSystemSleep, messageSystemWillSleep:`.

`energd/EngineHost.swift`: `shutdown` doc becomes "Hands the LED back to macOS, then exits. Runs on the engine queue so no XPC or IOKit event can re-apply state between the stop and the exit."

- [ ] **Step 9: Fix the app.**

`EnerG/AppModel.swift`: delete the `dischargeTarget` property and its doc comment.

`EnerG/PopoverView.swift`:
- Replace `ControlGrid` with:

```swift
private struct ControlGrid: View {
    let status: Status
    @Bindable var model: AppModel

    /// Pause, or released before an uninstall that then failed; a click on Pause resumes either.
    private var paused: Bool { status.state == .paused }
    private var toppingUp: Bool { status.toppingUp }

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                ToggleTile(symbol: "bolt.fill", title: "Top Up",
                           subtitle: toppingUp ? "Click to stop" : "Once to 100%",
                           isOn: toppingUp, disabled: paused) {
                    guard let current = model.status else { return }
                    Task { await model.perform(current.toppingUp ? .cancelTopUp : .topUp) }
                }
                ToggleTile(symbol: "pause.fill", title: "Pause",
                           subtitle: paused ? "macOS charging" : "EnerG active",
                           isOn: paused) {
                    guard let current = model.status else { return }
                    Task { await model.perform(.setPaused(current.state != .paused)) }
                }
            }
            GridRow {
                ToggleTile(symbol: "lightbulb.fill", title: "MagSafe LED",
                           subtitle: status.settings.ledMode.label,
                           isOn: status.settings.ledMode != .off, disabled: status.isUnavailable(.led)) {
                    guard let current = model.status else { return }
                    Task { await model.perform(.setLEDMode(current.settings.ledMode.next)) }
                }
                ToggleTile(symbol: "power", title: "Launch at Login",
                           subtitle: model.launchAtLogin ? "On" : "Off",
                           isOn: model.launchAtLogin) {
                    model.setLaunchAtLogin(!model.launchAtLogin)
                }
            }
        }
    }
}
```

- Delete `private struct DischargePopover` entirely.
- In `PowerFlowTile`:

```swift
    private func adapterFlowing(_ snapshot: BatterySnapshot) -> Bool {
        snapshot.adapterConnected
    }

    private func adapterText(_ snapshot: BatterySnapshot) -> String {
        guard snapshot.adapterConnected else { return "Unplugged" }
        return snapshot.adapterWatts.map { "\($0) W" } ?? "Connected"
    }
```

- In the "Copy" section:
  - Delete `defaultDischargeTarget` and its doc.
  - Delete `case .discharging: "Discharging"` from `ChargeState.label`.
  - Delete `case .discharge: "Discharge"` from `Feature.label`.
  - Replace the `LEDMode` extension with:

```swift
extension LEDMode {
    var label: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        }
    }

    /// Click order on the LED tile.
    var next: LEDMode {
        switch self {
        case .auto: .off
        case .off: .auto
        }
    }
}
```

- [ ] **Step 10: Run the core tests and the app build check.** Expected: tests pass and `** BUILD SUCCEEDED **`. Also `grep -rn -i "discharg\|blink\|autoSuppressed\|preventSleep\|\.lid(" Packages/EnerGKit/Sources EnerG energd` must print nothing.

- [ ] **Step 11: Commit.**

```bash
git add -A Packages/EnerGKit EnerG energd scripts/smoke.sh
git commit -m "refactor: remove Discharge and Auto-Discharge"
```

---

### Task 3: Native Limit module

Spec: Architecture → Native Limit, and "Native Limit behaviour". Assumes Task 1's outcome was clean, so there is no stuck recovery.

**Files:**
- Create: `Packages/EnerGKit/Sources/EnerGCore/NativeLimit.swift`
- Create: `Packages/EnerGKit/Tests/EnerGCoreTests/FakeLimitControls.swift`
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/NativeLimitTests.swift`

**Interfaces:**
- Consumes: `HardwareError` (existing).
- Produces:
  - `public protocol LimitControls: AnyObject` with `setMCL(_ percent: Int?) throws`, `writeOverride(_ percent: Int) throws`, `notifyDefaultsChanged()`, `smcLimit() -> Int?`, `pluggedIn() -> Bool`, `setAdapter(enabled: Bool) throws`, `wait(_ seconds: TimeInterval)`.
  - `public final class NativeLimit` with `init(controls: any LimitControls, settle: TimeInterval = 2)`, `func adapterWasCut()`, `func set(_ percent: Int?) throws -> Int?` and `static let powerUIMinimum = 80`.

- [ ] **Step 1: Write the fake.** `FakeLimitControls.swift`:

```swift
import Foundation
@testable import EnerGCore

/// Scripts how the smartcharging daemon reacts to an override; records every write.
final class FakeLimitControls: LimitControls {
    enum Call: Equatable {
        case setMCL(Int?), override(Int), notify, adapter(Bool)
    }
    enum Daemon {
        /// Pushes the override to the SMC on the notification (the % happened to change).
        case appliesOnNotify
        /// Pushes it only on a plug event, i.e. the CHIE pulse (the % is steady).
        case appliesOnPulse
        /// Never pushes it (a macOS that clamps the override).
        case neverApplies
    }

    var daemon = Daemon.appliesOnNotify
    var calls: [Call] = []
    /// What `CHLT[0]` reads; PowerUI writes land here at once.
    var chlt: Int? = 80
    var plugged = true
    var failingMCL = false
    var failingOverride = false
    /// Adapter-on writes that throw before one succeeds.
    var failingEnables = 0
    private var pending: Int?

    func setMCL(_ percent: Int?) throws {
        if failingMCL { throw HardwareError.io(-2) }
        calls.append(.setMCL(percent))
        chlt = percent
        pending = nil
    }

    func writeOverride(_ percent: Int) throws {
        if failingOverride { throw HardwareError.io(-3) }
        calls.append(.override(percent))
        pending = percent
    }

    func notifyDefaultsChanged() {
        calls.append(.notify)
        if daemon == .appliesOnNotify, let pending { chlt = pending }
    }

    func smcLimit() -> Int? { chlt }

    func pluggedIn() -> Bool { plugged }

    func setAdapter(enabled: Bool) throws {
        if enabled, failingEnables > 0 {
            failingEnables -= 1
            throw HardwareError.io(-1)
        }
        calls.append(.adapter(enabled))
        if enabled, daemon == .appliesOnPulse, let pending { chlt = pending }
    }

    func wait(_ seconds: TimeInterval) {}
}
```

- [ ] **Step 2: Write the failing tests.** `NativeLimitTests.swift`:

```swift
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

    @Test func pulseThrowsWhenTheAdapterStaysCut() {
        let (limit, _) = make {
            $0.daemon = .appliesOnPulse
            $0.failingEnables = 3
        }
        #expect(throws: HardwareError.self) { try limit.set(60) }
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

    @Test func powerUIFailureThrows() {
        let (limit, _) = make { $0.failingMCL = true }
        #expect(throws: HardwareError.self) { try limit.set(85) }
    }
}
```

- [ ] **Step 3: Run tests to verify they fail.** Run `swift test --package-path Packages/EnerGKit --filter NativeLimitTests`. Expected: compile error, "cannot find type 'LimitControls'".

- [ ] **Step 4: Implement.** `NativeLimit.swift`:

```swift
import Foundation

/// The machine primitives behind the native Charge Limit. `MacHardware` implements them; writes need root.
public protocol LimitControls: AnyObject {
    /// PowerUI: sets and enables the native limit (it accepts 80...100 only); nil disables it.
    func setMCL(_ percent: Int?) throws
    /// Writes `mclLimitValue` into root's `com.apple.smartcharging.topoffprotection` defaults.
    func writeOverride(_ percent: Int) throws
    /// Posts `com.apple.smartcharging.defaultschanged` so the smartcharging daemon re-reads its defaults.
    func notifyDefaultsChanged()
    /// The limit the firmware enforces (`CHLT` byte 0); nil when off or unreadable.
    func smcLimit() -> Int?
    /// A charger is physically plugged in.
    func pluggedIn() -> Bool
    /// SMC `CHIE`: false cuts adapter power.
    func setAdapter(enabled: Bool) throws
    func wait(_ seconds: TimeInterval)
}

/// Sets the native Charge Limit, including values below 80 that PowerUI rejects (ADR 0001). Those go through
/// the smartcharging defaults override. The daemon applies an override on its next % change or plug event,
/// so when the battery is steady a `CHIE` pulse supplies the plug event.
public final class NativeLimit {
    /// PowerUI's lowest accepted limit, and the fallback when a lower one doesn't take.
    public static let powerUIMinimum = 80
    private static let pollInterval: TimeInterval = 0.25

    private let controls: any LimitControls
    /// How long to wait, per attempt, for the daemon to push an override to the SMC.
    private let settle: TimeInterval
    /// `CHIE` was found cut at start: the next `set` disables the limit first, so macOS doesn't stay on battery.
    private var adapterCut = false

    public init(controls: any LimitControls, settle: TimeInterval = 2) {
        self.controls = controls
        self.settle = settle
    }

    /// Call once, before the first `set`, when the adapter was found cut (and has been turned back on).
    public func adapterWasCut() { adapterCut = true }

    /// Sets the limit; nil disables it. Returns the limit now in effect: `percent`, or `powerUIMinimum` when a
    /// lower value didn't take. Below `powerUIMinimum` while unplugged, `percent` is returned unverified, because the
    /// plug-in applies it. Throws when PowerUI fails or the adapter can't be turned back on after a pulse.
    /// Can block for about 5 s when a pulse is needed.
    public func set(_ percent: Int?) throws -> Int? {
        let reapplying = adapterCut
        if reapplying {
            try controls.setMCL(nil)
            adapterCut = false
        }
        guard let percent else {
            // Leave Apple's domain holding a value System Settings can show.
            if let current = controls.smcLimit(), current < Self.powerUIMinimum { try controls.setMCL(Self.powerUIMinimum) }
            try controls.setMCL(nil)
            return nil
        }
        if percent >= Self.powerUIMinimum {
            try controls.setMCL(percent)
            return percent
        }
        // A CHLT read straight after a write can return the old value, so after a re-apply it isn't trusted.
        if !reapplying, controls.smcLimit() == percent { return percent }
        if reapplying || controls.smcLimit() == nil { try controls.setMCL(Self.powerUIMinimum) }
        do {
            try controls.writeOverride(percent)
        } catch {
            return try fallBack()
        }
        controls.notifyDefaultsChanged()
        if waitUntilApplied(percent) { return percent }
        guard controls.pluggedIn() else { return percent }
        try pulse()
        if waitUntilApplied(percent) { return percent }
        return try fallBack()
    }

    private func fallBack() throws -> Int {
        try controls.setMCL(Self.powerUIMinimum)
        return Self.powerUIMinimum
    }

    private func waitUntilApplied(_ percent: Int) -> Bool {
        var waited: TimeInterval = 0
        while controls.smcLimit() != percent {
            if waited >= settle { return false }
            controls.wait(Self.pollInterval)
            waited += Self.pollInterval
        }
        return true
    }

    /// A cut and reconnect reads as a plug event to the smartcharging daemon.
    private func pulse() throws {
        try controls.setAdapter(enabled: false)
        controls.wait(1)
        // Turning the adapter back on is the safe direction: retry before giving up.
        for attempt in 1...3 {
            do {
                try controls.setAdapter(enabled: true)
                return
            } catch where attempt < 3 {
                controls.wait(0.5)
            }
        }
    }
}
```

> Check the retry loop. On the 3rd failed attempt the `catch where attempt < 3` clause doesn't match, so the error propagates out of `pulse()`. That's what `pulseThrowsWhenTheAdapterStaysCut` expects.

- [ ] **Step 5: Run tests to verify they pass.** Run `swift test --package-path Packages/EnerGKit`. Expected: all pass.

- [ ] **Step 6: Commit.**

```bash
git add Packages/EnerGKit/Sources/EnerGCore/NativeLimit.swift Packages/EnerGKit/Tests/EnerGCoreTests/FakeLimitControls.swift Packages/EnerGKit/Tests/EnerGCoreTests/NativeLimitTests.swift
git commit -m "feat: NativeLimit sets limits below 80 via the smartcharging override"
```

---

### Task 4: Effective limit, limits 50–100, and the sub-80 fallback warning

Spec: Engine/Policy "Effective limit", `Warning.lowLimitUnsupported`, and the `Settings.allowedLimits` / `Status` changes in Model/protocol.

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Hardware.swift`, `Model.swift`, `Protocol.swift`, `Engine.swift`
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift` (temporary pass-through), `Packages/EnerGKit/Sources/energ-smoke/main.swift`
- Modify: `EnerG/PopoverView.swift` (only the `Warning.label` case)
- Modify: `Packages/EnerGKit/Tests/EnerGCoreTests/FakeHardware.swift`, `ProtocolTests.swift`, `SettingsStoreTests.swift`
- Create: `Packages/EnerGKit/Tests/EnerGCoreTests/LimitTests.swift`

**Interfaces:**
- Consumes: Task 2's `Hardware`, `Status` and `Engine`.
- Produces:
  - `Hardware.setChargeLimit(_ percent: Int?) throws -> Int?`.
  - `Settings.allowedLimits == [50, 55, …, 100]`.
  - `Warning.lowLimitUnsupported`.
  - `Status(state:settings:snapshot:effectiveLimit:toppingUp:warnings:)` with `public var effectiveLimit: Int?`.
  - `FakeHardware.acceptsBelow80`.
  - Engine's private `effectiveLimit: Int?`, used by Task 5.

- [ ] **Step 1: Write the failing tests.**

In `FakeHardware.swift`, add the property and change `setChargeLimit`:

```swift
    /// false: limits below 80 don't take and 80 is in effect instead, like a macOS that clamps the override.
    var acceptsBelow80 = true
```

```swift
    func setChargeLimit(_ percent: Int?) throws -> Int? {
        if failing.contains(.chargeLimit) { throw HardwareError.notPrivileged }
        if let percent, failingLimits.contains(percent) { throw HardwareError.io(-2) }
        writes.append(.limit(percent))
        if let percent, percent < 80, !acceptsBelow80 { return 80 }
        return percent
    }
```

`LimitTests.swift`:

```swift
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
```

In `ProtocolTests.swift`:
- In `statusRoundTrips`, add `effectiveLimit: 80,` after `snapshot:`, and use `warnings: [.weakAdapter, .lowLimitUnsupported, .unavailable(.led), .batteryUnreadable]`.
- In `defaultSettings`, the second line becomes `#expect(Settings.allowedLimits == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100])`.

In `SettingsStoreTests.swift`, add:

```swift
    @Test func limitsBelowEightyLoad() throws {
        let store = SettingsStore(url: url)
        try store.save(Settings(chargeLimit: 60))
        #expect(store.load() == Settings(chargeLimit: 60))
        try store.save(Settings(chargeLimit: 45))
        #expect(store.load() == Settings())
    }
```

- [ ] **Step 2: Run tests to verify they fail.** Run `swift test --package-path Packages/EnerGKit`. Expected: compile errors (`effectiveLimit`, `lowLimitUnsupported`, the `setChargeLimit` return type).

- [ ] **Step 3: Implement.**

`Hardware.swift`:

```swift
    /// Sets the native Charge Limit; nil disables it. Returns the limit now in effect: `percent`, or 80 when
    /// this Mac doesn't accept a value below 80; nil when disabled.
    func setChargeLimit(_ percent: Int?) throws -> Int?
```

`Model.swift`:
- `Settings.allowedLimits` doc and value:

```swift
    /// Charge Limit values EnerG offers. 100 means "no limit"; below 80 goes through the smartcharging override (ADR 0001).
    public static let allowedLimits = Array(stride(from: 50, through: 100, by: 5))
```

- `Warning` gains a case after `weakAdapter`:

```swift
    /// A Charge Limit below 80 didn't take, so 80 is in effect.
    case lowLimitUnsupported
```

`Protocol.swift`, `Status`: add after `snapshot`:

```swift
    /// The native Charge Limit in effect: the setting, or 80 when a lower one didn't take. nil while off,
    /// paused, topping up, or when the Charge Limit is unavailable.
    public var effectiveLimit: Int?
```

Update `init` to `init(state:settings:snapshot:effectiveLimit:toppingUp:warnings:)` and assign it.

`Engine.swift`:
- Add after `snapshot`:

```swift
    /// What `setChargeLimit` reported in effect; nil when off, unavailable or not written yet.
    private var effectiveLimit: Int?
```

- In `handle`, `.start` also sets `effectiveLimit = nil`.
- In `apply`, the limit line becomes:

```swift
        if changed(\.chargeLimit, to: next) {
            write(.chargeLimit) {
                effectiveLimit = nil
                effectiveLimit = try hardware.setChargeLimit(next.chargeLimit)
            }
        }
```

- In `status()`, after the weak-adapter line:

```swift
        if let effective = effectiveLimit, let requested = applied?.chargeLimit, effective > requested {
            warnings.append(.lowLimitUnsupported)
        }
```

  Pass `effectiveLimit: effectiveLimit` to `Status`.

`MacHardware.swift`: a temporary pass-through until Task 6.

```swift
    public func setChargeLimit(_ percent: Int?) throws -> Int? {
        if let percent {
            // enableMCL: resets the limit to 80; setMCLLimit: also enables
            try check(powerui_set_limit(UInt8(percent)))
        } else {
            try check(powerui_set_enabled(false))
        }
        return percent
    }
```

`energ-smoke/main.swift`: `try hw.setChargeLimit(nil)` becomes `_ = try hw.setChargeLimit(nil)`, and `try hw.setChargeLimit(limit)` becomes `_ = try hw.setChargeLimit(limit)`.

`EnerG/PopoverView.swift`, `Warning.label`: add

```swift
        case .lowLimitUnsupported: "This Mac doesn't accept limits below 80%. Holding at 80%."
```

- [ ] **Step 4: Run the core tests and the app build check.** Expected: all pass, `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git add -A Packages/EnerGKit EnerG/PopoverView.swift
git commit -m "feat: Charge Limits 50-100 with an effective limit and a sub-80 fallback warning"
```

---

### Task 5: Limit Drain state and the Weak Adapter rule

Spec: Engine/Policy "Limit Drain", "Weak Adapter sample" and "LED (Auto)".

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGCore/Model.swift`, `Policy.swift`, `Engine.swift`
- Modify: `EnerG/PopoverView.swift` (only the `ChargeState.label` case)
- Test: `Packages/EnerGKit/Tests/EnerGCoreTests/LimitTests.swift`

**Interfaces:**
- Consumes: Task 4's `effectiveLimit` in Engine and `FakeHardware.acceptsBelow80`.
- Produces: `ChargeState.limitDrain` and `Policy.update(settings:snapshot:effectiveLimit:countsWeakSample:session:)`.

- [ ] **Step 1: Write the failing tests.** Append to `LimitTests`:

```swift
    // Above the limit macOS runs the Mac from the battery itself; that is no Weak Adapter.
    @Test func aboveTheLimitIsLimitDrainNotWeakAdapter() {
        let (engine, hw) = started()
        hw.snap.percent = 83
        hw.snap.isCharging = false
        hw.snap.batteryWatts = -11
        var status = engine.handle(.tick)
        #expect(status.state == .limitDrain)
        #expect(hw.writes == [.led(.green)])
        status = engine.handle(.tick)
        #expect(!status.warnings.contains(.weakAdapter))
    }

    @Test func weakAdapterAtTheLimitCounts() {
        let (engine, hw) = started()
        hw.snap.percent = 80
        hw.snap.isCharging = false
        hw.snap.batteryWatts = -5
        #expect(!engine.handle(.tick).warnings.contains(.weakAdapter))
        let status = engine.handle(.tick)
        #expect(status.warnings.contains(.weakAdapter))
        #expect(status.state == .atLimit)
    }

    @Test func weakAdapterCountsAtAnyPercentWithoutALimit() {
        let (engine, hw) = started(Settings(chargeLimit: 100))
        hw.snap.percent = 92
        hw.snap.batteryWatts = -5
        engine.handle(.tick)
        #expect(engine.handle(.tick).warnings.contains(.weakAdapter))
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
```

- [ ] **Step 2: Run tests to verify they fail.** Run `swift test --package-path Packages/EnerGKit --filter LimitTests`. Expected: compile error, "type 'ChargeState' has no member 'limitDrain'".

- [ ] **Step 3: Implement.**

`Model.swift`: `ChargeState` becomes `case charging, atLimit, limitDrain, toppingUp, paused, onBattery, unknown`.

`Policy.swift`, `update`:
- New signature: `static func update(settings: Settings, snapshot: BatterySnapshot, effectiveLimit: Int?, countsWeakSample: Bool, session s: inout Session)`.
- Add to its doc: "`effectiveLimit`: above it the battery is in a Limit Drain, which is no Weak Adapter."
- The weak line becomes:

```swift
        // Charging is expected at or below the limit in effect; above it macOS drains to it on purpose.
        let chargingExpected = effectiveLimit.map { snapshot.percent <= $0 } ?? true
        let weak = snapshot.adapterConnected && chargingExpected && snapshot.batteryWatts < 0
```

`Engine.swift`:
- In `evaluate`, pass `effectiveLimit: effectiveLimit` to `Policy.update`.
- In `state()`, before the last line:

```swift
        if let limit = effectiveLimit, snapshot.percent > limit { return .limitDrain }
```

`EnerG/PopoverView.swift`, `ChargeState.label`: add `case .limitDrain: "Draining to limit"`.

- [ ] **Step 4: Run the core tests and the app build check.** Expected: all pass, `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git add -A Packages/EnerGKit EnerG/PopoverView.swift
git commit -m "feat: Limit Drain state; Weak Adapter only where charging is expected"
```

---

### Task 6: MacHardware drives NativeLimit

Spec: Architecture → MacHardware, the `adapterWasCut()` start check, and Tooling.

**Files:**
- Modify: `Packages/EnerGKit/Sources/EnerGMac/MacHardware.swift`
- Modify: `Packages/EnerGKit/Sources/energ-smoke/main.swift`, `scripts/smoke.sh`
- Modify: `energd/main.swift`

**Interfaces:**
- Consumes: Task 3's `LimitControls` and `NativeLimit`, and Task 4's `Hardware.setChargeLimit -> Int?`.
- Produces: `MacHardware: Hardware, LimitControls`, `MacHardware.recoverAdapter()` and `MacHardware.smcLimit()`.

- [ ] **Step 1: Implement the primitives in `MacHardware.swift`.**
  - Add `import notify` under the other imports. If the module doesn't resolve, `notify_post` is also exported by `Darwin`; drop the import then.
  - Declaration: `public final class MacHardware: Hardware, LimitControls {`.
  - Header doc, append: "The native Charge Limit goes through `NativeLimit`, with this class as its `LimitControls`."
  - Properties:

```swift
    /// Holds `self` as its controls; MacHardware lives for the whole process, so the cycle is harmless.
    private lazy var nativeLimit = NativeLimit(controls: self)
```

  - Replace `setChargeLimit` with:

```swift
    public func setChargeLimit(_ percent: Int?) throws -> Int? {
        try nativeLimit.set(percent)
    }

    /// Turns `CHIE` back on if a crash mid-pulse (or an older build's Discharge) left the adapter cut; the next
    /// `setChargeLimit` then re-applies the limit so macOS doesn't stay on battery. energd calls it once before `.start`.
    public func recoverAdapter() {
        guard let chie = try? read("CHIE", size: 1), chie[0] != 0x00 else { return }
        do { try setAdapter(enabled: true) } catch {
            log.error("adapter re-enable at start failed: \(String(describing: error), privacy: .public)")
        }
        nativeLimit.adapterWasCut()
    }

    // MARK: - LimitControls

    public func setMCL(_ percent: Int?) throws {
        if let percent {
            // enableMCL: resets the limit to 80; setMCLLimit: also enables. Accepts 80...100 only.
            try check(powerui_set_limit(UInt8(percent)))
        } else {
            try check(powerui_set_enabled(false))
        }
    }

    /// A String, not a CFString: a static CF value isn't concurrency-safe under Swift 6.
    private static let smartChargingDomain = "com.apple.smartcharging.topoffprotection"

    public func writeOverride(_ percent: Int) throws {
        // energd runs as root, so this is root's domain, the one the smartcharging daemon reads.
        let domain = Self.smartChargingDomain as CFString
        CFPreferencesSetValue("mclLimitValue" as CFString, NSNumber(value: percent), domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw HardwareError.io(-3)
        }
    }

    public func notifyDefaultsChanged() {
        notify_post("com.apple.smartcharging.defaultschanged")
    }

    /// `CHLT` = `[limit, band, status]`; byte 0 is the limit the firmware enforces, 0 when off.
    public func smcLimit() -> Int? {
        guard let bytes = try? read("CHLT", size: 3), bytes[0] != 0 else { return nil }
        return Int(bytes[0])
    }

    /// Unknown counts as plugged in: a pulse with nothing plugged in is harmless.
    public func pluggedIn() -> Bool { physicallyPlugged() ?? true }

    public func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
```

  - If `CHLT` reads a different size than 3 on this Mac (`read` throws `keyMissing`), check it with Task 1's probe and use that size.

- [ ] **Step 2: energd calls `recoverAdapter()`.** In `energd/main.swift`, directly before `host.handle(.start)`:

```swift
hardware.recoverAdapter()
```

- [ ] **Step 3: energ-smoke and smoke.sh.**

`energ-smoke/main.swift`:
- `usage` becomes `"usage: energ-smoke status | get-limit | adapter on|off | led system|off|green|orange | limit <50-100>|off"`.
- `get-limit` prints both values: `print("\(enabled ? "\(limit)" : "off") CHLT=\(hw.smcLimit().map(String.init) ?? "off")")`.
- The `limit` cases become:

```swift
    case ("limit", "off"):
        print(try hw.setChargeLimit(nil).map(String.init) ?? "off")
    case ("limit", _):
        guard let limit = Int(argument), (50...100).contains(limit) else { print(usage); exit(2) }
        print(try hw.setChargeLimit(limit).map(String.init) ?? "off")   // the limit now in effect
```

`scripts/smoke.sh`:
- `ORIG=$(S get-limit)` becomes `ORIG=$(S get-limit | cut -d' ' -f1)`.
- Before `echo "== limit off (expect off)"`, add:

```bash
echo "== limit 60 (expect 60; 80 means this macOS rejects the override)"; S limit 60; S get-limit
```

- [ ] **Step 4: Build and run the tests.** Run `swift build --package-path Packages/EnerGKit --product energ-smoke && swift test --package-path Packages/EnerGKit`. Expected: build OK, all pass.
  - Then, unprivileged: `Packages/EnerGKit/.build/debug/energ-smoke get-limit`. Expected: e.g. `80 CHLT=80`.

- [ ] **Step 5: App build check.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit.**

```bash
git add -A Packages/EnerGKit energd/main.swift scripts/smoke.sh
git commit -m "feat: MacHardware drives the native limit through NativeLimit"
```

---

### Task 7: App copy and controls for the new limits

Spec: App.

**Files:**
- Modify: `EnerG/PopoverView.swift`

**Interfaces:**
- Consumes: `Status.effectiveLimit`, `ChargeState.limitDrain` and `Warning.lowLimitUnsupported`.
- Produces: `Status.stateLabel`, which is app-only.

- [ ] **Step 1: State line and caption.** In the Copy section, add to `extension Status`:

```swift
    /// The state line under the battery %. "At limit" covers the firmware band below the limit too,
    /// where macOS doesn't charge until the battery drops 5 points under it.
    var stateLabel: String {
        switch state {
        case .limitDrain:
            return effectiveLimit.map { "Draining to \($0)%" } ?? state.label
        case .atLimit:
            guard let limit = effectiveLimit, let percent = snapshot?.percent else { return "Not charging" }
            return percent >= limit ? "Holding at \(limit)%" : "Not charging · resumes below \(limit - 5)%"
        default:
            return state.label
        }
    }
```

In `BatteryTile`:
- `Text(status.state.label).foregroundStyle(.secondary)` becomes `Text(status.stateLabel).foregroundStyle(.secondary)`.
- Directly after that first `HStack` (the one with the big %), add:

```swift
            if status.state == .limitDrain {
                Text("macOS runs the Mac from the battery until it's back at the limit.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

- [ ] **Step 2: Slider range.** In `BatteryTile`, `in: 80...100, step: 5` becomes `in: 50...100, step: 5`.

- [ ] **Step 3: Adapter row during a Limit Drain.** In `PowerFlowTile`:

```swift
    /// During a Limit Drain the adapter is attached but idle: macOS runs the Mac from the battery.
    private func adapterFlowing(_ snapshot: BatterySnapshot) -> Bool {
        snapshot.adapterConnected && status.state != .limitDrain
    }

    private func adapterText(_ snapshot: BatterySnapshot) -> String {
        guard snapshot.adapterConnected else { return "Unplugged" }
        let rated = snapshot.adapterWatts.map { "\($0) W" } ?? "Connected"
        return status.state == .limitDrain ? "\(rated) · idle" : rated
    }
```

- [ ] **Step 4: App build check.** Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit.**

```bash
git add EnerG/PopoverView.swift
git commit -m "feat: popover shows Limit Drain, the band below the limit, and limits from 50%"
```

---

### Task 8: Base spec and README

Spec: Tooling and docs.

**Files:**
- Modify: `docs/superpowers/specs/2026-10-20-energ-design.md`, `README.md`

**Interfaces:** none.

- [ ] **Step 1: Base spec.**
  - Under the title, add: `> **Superseded in part (2026-10-21):** Discharge, Auto-Discharge, Discharge Target, Blink LED mode and the sleep assertion were removed and limits extended to 50–100. See [Limits redesign](2026-10-21-energ-limits-redesign-design.md). Sections below that describe them are historical.`
  - Facts table: the `CHIE` row's "Used for" cell `**Discharge**` becomes `Sub-80 trigger pulse (ADR 0001)`. The PowerUI row's "Used for" becomes `**Charge Limit** 80–100; 50–75 via the smartcharging override (ADR 0001)`.
  - Replace the whole "**Native limit drains to the limit (2026-10-20, Mac17,8):**" bullet, with its sub-bullets, by the bullets of the redesign spec's "New platform facts" section: Limit Drain, Asleep, Displayed vs raw %, `CHLT`, Sub-80 limits, AlDente 1.39.4. Copy them verbatim.
  - Behaviour table:
    - Delete the rows "Above limit, Auto-Discharge on" and "Manual Discharge to target T".
    - Delete the "Adapter (`CHIE`)" and "Sleep assertion" columns from every row.
    - Add the row `| Above limit, adapter attached (Limit Drain) | limit | green |`.

- [ ] **Step 2: README.**
  - Intro sentence: `Charge Limit, Discharge / Auto-Discharge, MagSafe LED control, Top Up and Pause` becomes `Charge Limit (50–100%), MagSafe LED control, Top Up and Pause`.
  - "How it works": replace the first two bullets with:

```markdown
- **Charge Limit** uses the native macOS limit through the private PowerUI framework. macOS itself drains the battery down to a lowered limit while plugged in (the Limit Drain), then holds it on AC.
- **Limits below 80%**, which PowerUI rejects, are written to the smartcharging daemon's own defaults. When the battery is steady, a one-second cut of adapter power (SMC key `CHIE`) makes the daemon apply them. See [ADR 0001](docs/adr/0001-sub-80-limits-via-smartcharging-override.md).
```

  - The next bullet, "It cuts USB-C input as well as MagSafe, …", becomes `- The SMC key \`AC-W\` reports whether any charger is physically plugged in.`
  - "Uninstall", the "Uninstall Anyway" bullet: "it restores the adapter and LED as it stops" becomes "it hands the LED back as it stops". The Login Items bullet: "the adapter and LED are restored" becomes "the LED is handed back".

- [ ] **Step 3: Check for leftovers.** Run `grep -n -i "auto-discharge\|blink" README.md`. Expected: nothing.

- [ ] **Step 4: Commit.**

```bash
git add README.md docs/superpowers/specs/2026-10-20-energ-design.md
git commit -m "docs: base spec and README for the limits redesign"
```

---

### Task 9: Install and verify on device (with the user)

Spec "Verification" 2–3. The user runs every `sudo` command; the agent samples state unprivileged with `energ-smoke get-limit`, `energ-smoke status` and `pmset -g batt`, and reports.

- [ ] **Step 1: Test and install.**
  - Run `swift test --package-path Packages/EnerGKit`. Expected: all pass.
  - Run `scripts/install.sh`. Expected: `** BUILD SUCCEEDED **`, and EnerG opens.
  - Ask the user to run `sudo launchctl kickstart -k system/app.energ.energd`, and to quit AlDente.
  - The user resumes EnerG if it is paused.

- [ ] **Step 2: (a) Set 60 at ~80%.**
  - The user sets the slider to 60.
  - Expected within ~5 s: `get-limit` shows `60 CHLT=60`, and the popover shows "Draining to 60%" with the caption and "· idle" on the adapter.
  - Over two minutes, no Weak Adapter notice appears.

- [ ] **Step 3: (b) Hold at 60.** This one is long; run it in the background, or overnight with `caffeinate -i` and the lid open.
  - Once the battery reaches 60, `status` shows `batteryWatts` ≈ 0 for ≥ 10 min, and the popover shows "Holding at 60%".

- [ ] **Step 4: (c) Back to 80.**
  - The user sets 80.
  - Expected: `80 CHLT=80`, charging resumes, and System Settings → Battery → Charge Limit shows 80.

- [ ] **Step 5: (d) Pause and resume at 60.**
  - Pause → `get-limit` shows `off CHLT=off`.
  - The user runs `sudo defaults read com.apple.smartcharging.topoffprotection mclLimitValue` → `80`.
  - Resume → `60 CHLT=60`.

- [ ] **Step 6: (e) Sleep and wake at 60.**
  - The user closes the lid for 1 min, then opens it.
  - The agent checks `log show --last 5m --predicate 'subsystem == "app.energ"'` and `get-limit`. Expected: `60 CHLT=60`, and no adapter cut (no "Battery Power" blip in `pmset -g log | tail -20`).

- [ ] **Step 7: (f) Weak Adapter at the limit.** Only if a low-watt charger is at hand.
  - Under load at the limit, the notice appears after about 60 s.
  - Otherwise mark this check skipped.

- [ ] **Step 8: Report.**
  - Give the user a pass/fail line per check.
  - Record any failure as a new issue for systematic debugging; don't patch it inline.
  - Append an "Outcome (date)" section to the redesign spec with the results, and commit it.

# EnerG: Limits redesign (Limit Drain, sub-80 limits, no Discharge)

Date: 2026-10-21
Status: approved (brainstorming)
Base: [EnerG design](2026-10-20-energ-design.md) · Previous round: [Polish round 1](2026-10-20-energ-polish-design.md) · Glossary: [CONTEXT.md](../../../CONTEXT.md) · Decision: [ADR 0001](../../adr/0001-sub-80-limits-via-smartcharging-override.md)

## Purpose

EnerG's goal, in order: maximize battery lifetime, then keep total capacity (prevent degradation).

On-device probes changed the model:
- macOS already drains the battery to the native limit by itself (**Limit Drain**). That makes Auto-Discharge redundant and caused the false Weak Adapter.
- The native limit can be set below 80 % through an undocumented override, and the firmware drains to it and holds there on AC. Manual Discharge loses its last use, because no EnerG feature can hold a level below the limit.

This round:
1. Limits from 50 to 100 %.
2. Discharge and Auto-Discharge removed.
3. A Limit Drain state.
4. A Weak Adapter rule that excludes the Limit Drain.
5. Honest copy for the firmware band below the limit.

It also resolves the polish round's open issues 1–3.

## New platform facts (probes, 2026-10-20/21, Mac17,8, macOS 27)

These are added to the base spec's "Verified platform facts". The existing bullet "Native limit drains to the limit" is replaced by the first one.

- **Limit Drain:**
  - With the adapter attached and the battery above the native limit, macOS reports "AC Power", yet the battery supplies the whole system draw: `B0AC` × `B0AV` ≈ −`PSTR`, and the adapter is idle.
  - It stops in the same sample in which the *displayed* % reaches the limit. Battery current then reads 0, and AC holds at the limit for hours, with no overshoot.
  - Re-confirmed with AlDente quit: it is firmware behaviour.
- **Asleep:** the drain is about 0 (raw capacity 6684 → 6680 mAh in 28 min).
- **Displayed vs raw %:** `CurrentCapacity` (the displayed %) runs ~3–4 points above `RemainingCapacity / FullChargeCapacity`. The native limit compares against the displayed %, and so does EnerG.
- **`CHLT` = `[limit, 0x05, status]`:** the status byte reads `03` during a Limit Drain, `05` while holding at the limit, and `00` while the limit is off. It is logged for diagnostics only.
- **Sub-80 limits:**
  - PowerUI `setMCLLimit:` rejects values below 80 (it returns false).
  - The value lives in root's defaults domain `com.apple.smartcharging.topoffprotection`, key `mclLimitValue`. Writing it, then posting `com.apple.smartcharging.defaultschanged`, makes PowerUI `get` report the new value.
  - The daemon pushes the value to `CHLT` only on its next displayed-% change or plug event. While the % is steady, a `CHIE` pulse (`08`, ~1–3 s, `00`) serves as the plug event; raising 70 → 72 worked that way.
  - Verified: 70 was applied, the Limit Drain reached 70 and held 3 h on AC with battery current 0. 74 and 66 applied on a notify followed by a % tick.
  - No chime or visible effect on the pulse.
  - `enableMCL:` resets the value to 80.
- **AlDente 1.39.4** uses the same mechanism (from its binary's strings: PowerUI 80…100 check, "PreferencesBackend", `mclLimitValue`, "pulsing discharge key").

## Changes

### Architecture

| Module | Interface | Seam | Depth rationale | Test surface |
|---|---|---|---|---|
| **Engine** (EnerGCore) | `handle(Event) -> Status`. `Event` loses `.willSleep` and `.lid(closed:)`. Keeps `effectiveLimit: Int?` next to `applied`. | — | No adapter or sleep bookkeeping and no unstick left. | FakeHardware |
| **Policy** | `update(settings:snapshot:effectiveLimit:countsWeakSample:session:)`; `actuation(...) -> Actuation { chargeLimit, led }` | — | Pure rules. Limit Drain and Weak Adapter both key off `effectiveLimit`. | Through Engine tests |
| **`Hardware` port** | `snapshot()`. `setChargeLimit(_ n: Int?) throws -> Int?` returns the limit **now in effect**: n, or 80 when sub-80 isn't accepted; nil means off. `setLED(_:)`. Removed: `setAdapter`, `setPreventSleep`. Postcondition: the adapter is on when any call returns. | EnerGCore ↔ EnerGMac | The Engine learns about the fallback as a value, not as a special error. A throw still means "Charge Limit unavailable". | `FakeHardware.acceptsBelow80` (default true) |
| **Native Limit** (new, EnerGCore) | `NativeLimit(controls:)`. `set(_ n: Int?) throws -> Int?` has the same contract as `Hardware.setChargeLimit`. `adapterWasCut()` is called once at start (see below). | `LimitControls` port: `setMCL(Int?) throws`, `writeOverride(Int) throws`, `notifyDefaultsChanged()`, `smcLimit() -> Int?` (`CHLT[0]`, nil if off or unreadable), `pluggedIn() -> Bool`, `setAdapter(Bool) throws`, `wait(TimeInterval)` | Deep: about six branches behind one call, plus a safety invariant (`CHIE` ends at `00`). It replaces the Engine's old unit-tested unstick, so its tests move here. | `FakeLimitControls` scripts the daemon's reaction: applies on notify, applies on pulse, never applies, or unplugged |
| **MacHardware** (EnerGMac) | Implements `Hardware` by delegating to `NativeLimit`, and provides `LimitControls` as thin primitives: PowerUI, CFPreferences (root's domain, `kCFPreferencesAnyHost`), `notify_post`, SMC. | adapter | Shallow on purpose: each primitive is one OS call. | Task 1 spike + device checks |

Dependency categories:
- PowerUI, SMC, CFPreferences and `notify` are true external dependencies, untestable in CI, so they sit behind ports.
- Both ports have two adapters (Mac and Fake), so both are real seams.

### Native Limit behaviour

`set(n)`:
- **n ≥ 80**: `setMCL(n)` and return n. If the current value is below 80, PowerUI overwrites it, which is fine.
- **n < 80**:
  1. If `smcLimit() == n`, return n (wake or start with the value already in place: no writes, no pulse). Skipped when re-applying after `adapterWasCut()`, since a `CHLT` read straight after a write can be stale.
  2. `setMCL(80)` only when the native limit is off (`smcLimit()` nil) or when re-applying. Then `writeOverride(n)` (if it throws: fallback), then `notifyDefaultsChanged()`.
  3. Poll `smcLimit()` for up to ~2 s.
  4. If it isn't n: when not plugged in, return n unverified: the plug-in event applies it. Otherwise pulse: `setAdapter(false)`, `wait(1)`, `setAdapter(true)`, then poll ~2 s again. A failed cut falls back (the adapter was never cut). A failed re-enable is retried up to 3 times, 0.5 s apart; if all fail, `set` throws (Charge Limit unavailable) and MacHardware's snapshot turns the adapter back on at the next event.
  5. Still not n: `setMCL(80)` and return 80 (fallback).
- **nil**: if `smcLimit()` is below 80, call `setMCL(80)` first, so Apple's domain holds a value System Settings can show. Then `setMCL(nil)` (`disableMCL`).
- **Stuck recovery** after a pulse above the new limit: decided by the Task 1 spike. If the spike shows "Battery Power" stuck, NativeLimit runs disable → `setMCL(80)` → override → notify before polling again.
- **`adapterWasCut()`**: `MacHardware.snapshot()` reads `CHIE` on every Engine event, `.start` included (energ-smoke opts out, so its `adapter off` sticks). If it isn't `00` (a pulse whose re-enable failed, a crash mid-pulse, or an upgrade from a build that was mid-Discharge), it writes `00` and calls this. The snapshot runs on the Engine's serial context, so never mid-pulse. The next `set` then starts with disable → set, the old unstick. The Engine's `.start` writes the limit unconditionally (`applied = nil`), so after a restart that next `set` always happens; mid-run, the adapter is back on at once and the unstick waits for the next `set`.
- A limit change can block energd for up to ~5 s. That only happens when the % is steady and a pulse is needed.

### Engine / Policy

- **Removed:**
  - `Session`: `dischargeTarget`, `dischargeJustEnded`, `autoSuppressed`, `sleeping`, `lidClosed`, `canStartDischarge`.
  - Engine: adapter, unstick (`reapplyLimit`, `limitLeftOff`), sleep assertion, and the catch path's adapter re-enable.
  - `Policy`: the Auto-Discharge branch.
  - `.stop` now only hands the LED back to the system.
- **Effective limit:**
  - `applied.chargeLimit` stores the *requested* value, so the Engine doesn't re-request it every tick; a re-request could pulse every 30 s.
  - `effectiveLimit` stores what `setChargeLimit` returned. It is nil when the write threw (Charge Limit unavailable) or the limit is off.
  - Retries happen only on `.start`, `.didWake` (`applied = nil`) and on a limit change.
- **`Warning.lowLimitUnsupported`** is shown while `effectiveLimit` is not nil and is above the requested limit. Copy: "This Mac doesn't accept limits below 80 %. Holding at 80 %."
- **Limit Drain:** `ChargeState.limitDrain` when not paused, not Top Up, adapter connected, `effectiveLimit != nil`, and `percent > effectiveLimit`. It replaces `.discharging`.
- **Weak Adapter sample:** adapter connected, `batteryWatts < 0`, and either `effectiveLimit == nil` or `percent ≤ effectiveLimit`. Only ticks count, and it takes 2 ticks.
  - The "first tick after a Discharge" skip goes.
  - The skip for `.powerChanged` stays.
- **LED (Auto):** orange while charging, green otherwise when plugged in, which includes Limit Drain and the band. Off mode is unchanged. Blink is removed.

### Model / protocol

- `Settings.allowedLimits` = 50, 55, … 100. The `autoDischarge` field is removed, and an old key is ignored. A stored `ledMode: "blink"` falls back to Auto through the existing per-field decoder.
- `Feature`: `chargeLimit`, `led`. `.discharge` is removed.
- `ChargeState`: `.discharging` is removed and `.limitDrain` added.
- `Status`: `dischargeTarget` is removed and `effectiveLimit: Int?` added.
- `Request`: `discharge(to:)`, `cancelDischarge` and `setAutoDischarge` are removed.
- `LEDMode`: `auto`, `off`. `LEDState`: `blinkSlow` is removed.
- The app and energd ship together (install.sh), so there is no compatibility shim.

### energd

- `SystemEvents` drops the lid notifier. It still acknowledges sleep but no longer sends `.willSleep`. `.didWake` stays.

### App

- **Limit slider** 50…100, step 5. No toggle and no note about the mechanism.
- **Discharge and Auto-Discharge tiles** are removed, along with `DischargePopover`, `AppModel.dischargeTarget` and `defaultDischargeTarget`.
- **State line** uses `effectiveLimit` (call it L):
  - `.limitDrain`: "Draining to L %".
  - Plugged in and not charging: "Holding at L %" when % ≥ L; "Not charging · resumes below (L − 5) %" when L − 5 ≤ % < L; otherwise "Not charging".
  - The other states are unchanged.
- **Adapter row** during `.limitDrain`: "70 W · idle".
- **Limit Drain caption**, one line: "macOS runs the Mac from the battery until it's back at the limit."
- **LED Mode** cycles Auto ↔ Off.

### Tooling and docs

- `energ-smoke limit <50-100>|off` goes through `NativeLimit` and prints the effective limit. `energ-smoke get-limit` also prints `CHLT`.
- Base spec:
  - Platform facts as above.
  - Behaviour table: the Auto-Discharge and manual Discharge rows go; a Limit Drain row is added ("Above limit, adapter attached | limit | on | green | none").
  - The `CHIE` row becomes "sub-80 trigger pulse".
- README: features list (no Discharge, limits 50–100), how it works (the override + pulse, linking ADR 0001).
- Tests:
  - Delete `DischargeTests.swift`, and with it `autoDischargeOffHoldsAboveLimit`.
  - Add `NativeLimitTests` and Limit Drain / Weak Adapter / effective-limit tests to the Engine suites.

## Verification

1. **Task 1, device spike (before NativeLimit's stuck path is written).**
   - Set the limit to 60 while the % is steady above it, then pulse.
   - Check whether `CHLT` updates, and whether macOS returns to "AC Power" within 2 s or sticks on "Battery Power".
   - Record the outcome in the base spec facts.
2. **`swift test` passes.**
3. **Device checks:**
   - (a) At 80, set 60: `CHLT` = `3c…`, the popover shows "Draining to 60 %", and there is no Weak Adapter.
   - (b) Hold at 60 for ≥ 10 min: battery current is 0 and the state reads "Holding at 60 %".
   - (c) Set 80 again: it charges to 80, and PowerUI and System Settings show 80.
   - (d) Pause, then resume: Pause disables the limit and leaves `mclLimitValue` at 80; resume re-applies 60.
   - (e) Sleep and wake at 60: no pulse if `CHLT` is already 60 (log).
   - (f) A Weak Adapter at the limit under load, if a low-watt charger is at hand.

## Open issues

- The override is undocumented, and a macOS update may clamp it. The fallback to 80 and the warning cover that.
- Whether System Settings' Charge Limit pane shows or resets a sub-80 value is unknown and not handled.

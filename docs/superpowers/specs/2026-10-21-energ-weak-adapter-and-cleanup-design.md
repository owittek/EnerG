# EnerG: Weak Adapter as information, plus known-issue cleanup

Date: 2026-10-21
Status: approved (brainstorming)
Base: [EnerG design](2026-10-20-energ-design.md) · Previous round: [Limits redesign](2026-10-21-energ-limits-redesign-design.md) · Glossary: [CONTEXT.md](../../../CONTEXT.md)

## Purpose

The Weak Adapter warning flickers under a marginal load, and an alarm is the wrong tool for it. The user only needs to know that a charger is suited to light work; whether that is enough is the user's call. This round turns Weak Adapter into a note on the adapter's rating. It also fixes the open issues left by the limits redesign.

## 1. Weak Adapter (information only)

- **Weak Adapter** = an adapter rated below 50 W (`snapshot.adapterWatts < 50`). Ratings cluster at 20/30/35/45 W and at 61–140 W, so 45 W counts as weak.
- The text under the popover's adapter icon, first match wins. A note sits on its own smaller line below the rating, because "N W · light work" doesn't fit a third of the row (seen on device):

  | Condition | Text | Note |
  |---|---|---|
  | Adapter not connected | "Unplugged" | — |
  | `adapterWatts` unknown | "Connected" | — |
  | `adapterWatts < 50` | "N W" | "light work", also during a Limit Drain |
  | State is `.limitDrain` | "N W" | "idle" |
  | Otherwise | "N W" | — |

- When the charger can't cover the load, the battery tile already shows the battery supplying power (negative W). Nothing else warns.
- Removed:
  - `Warning.weakAdapter` and its label.
  - `Session.weakSamples`, plus the Weak Adapter rule and `chargingExpected` in `Policy.update`.
  - The `countsWeakSample` parameter and the `effectiveLimit` parameter of `Policy.update`, and `evaluate(countsWeakSample:)`. The "update sees the previous `effectiveLimit`" issue goes away with them.
  - The Weak Adapter tests in `LimitTests`, `TopUpAndWarningsTests`, `EngineBasicsTests` and the `ProtocolTests` fixture.
- Compatibility: an energd still running the old build may send `weakAdapter`, which the new app fails to decode until the user runs `kickstart`. That window is accepted; there is no shim.

## 2. Testable labels

- `ChargeState.label`, `Status.stateLabel` and new `Status.adapterLabel` and `Status.adapterNote` (the table above, with a `weakAdapterBelowWatts = 50` constant) move from `EnerG/PopoverView.swift` into EnerGCore.
- `PowerFlowTile.adapterText` is replaced by `status.adapterLabel` with `status.adapterNote` on a second line.
- The two `extension Status` blocks left in the app are merged.
- The new tests cover every row of the adapter table, plus `stateLabel` for a Limit Drain, holding, the firmware band, and below the band.

## 3. Engine and NativeLimit fixes

- **Re-enable failure no longer latches at once:**
  - When all 3 `setAdapter(enabled: true)` attempts in `pulse()` fail, `NativeLimit` marks the adapter as cut itself and throws `HardwareError.adapterCut`.
  - On `adapterCut` the Engine doesn't mark `.chargeLimit` unavailable. It forces a Charge Limit re-set on the next event, in the same way as a failed wake re-assert.
  - By then the heal in `snapshot()` has turned `CHIE` back on, and the re-set runs disable→set, so macOS leaves "Battery Power".
  - A second `adapterCut` in a row latches `.chargeLimit` unavailable, so a broken `CHIE` can't pulse on every tick.
- **Re-verify an unplugged sub-80 limit on plug-in:** a sub-80 Charge Limit written while the snapshot shows the adapter unplugged is flagged unverified. When `adapterConnected` goes from false to true between snapshots and the flag is set, the Engine re-sets the Charge Limit once; the re-set is made plugged in, so it clears the flag, and later plug-ins (or flickers) write nothing. A limit written plugged in is never re-set. If macOS clamps the override, `set` falls back to 80 and `lowLimitUnsupported` shows. Limits of 80 and up, and no limit, are not re-set.
- **Limit Drain requires `!isCharging`:** `state()` returns `.limitDrain` only when the battery is above `effectiveLimit` and not charging. Right after a lower limit is set, the popover therefore shows "Charging" until macOS actually stops charging.
- **Re-apply:**
  - Leave no sub-80 `mclLimitValue` behind: `set` reads `smcLimit()` before the re-apply disable and uses that value for the "below 80 → `setMCL(80)` first" step of the nil path.
  - Stale read: when re-applying, `waitUntilApplied` waits one `pollInterval` before its first `CHLT` read.
- **Spurious heal:** `healAdapter()` waits 0.25 s after a non-zero `CHIE` read and reads it again. It heals only if the second read is also non-zero. The extra wait only happens in that rare case.

## 4. Tests and fakes

- `FakeLimitControls`:
  - Records `wait` calls.
  - Gains a stale-read mode: after a write, the first N `smcLimit()` reads return the old value.
  - Can apply an override only after N polls.
- New tests, written before each fix:
  - **Settle timeout:** applied within the settle window means no pulse; never applied means a pulse, then the fallback.
  - **Stale read on re-apply:** a `wait` is recorded before the first poll, and the stale value isn't trusted.
  - **Re-apply then disable:** with a sub-80 limit, `setMCL(80)` runs before `setMCL(nil)`.
  - **`adapterCut`, Engine side:**
    - The first failure retries on the next event and doesn't latch.
    - A second failure in a row latches.
    - A success resets the count.
  - **`adapterCut`, NativeLimit side:** after the throw, the next `set` re-applies (disable first).
  - **Plug-in re-verify:**
    - Unplugged→plugged after a sub-80 limit set while unplugged calls `setChargeLimit` again, once; a second unplug/plug writes nothing.
    - A sub-80 limit set while plugged in is not re-set on a later plug-in.
    - With a limit of 80 or more it doesn't re-set.
    - A clamping fake ends on 80 with `lowLimitUnsupported`.
  - **Limit Drain while charging:** above the limit and charging is reported as `.charging`.
  - **Labels:** see section 2.
- The spurious-heal re-read is in `MacHardware` and has no fake. It is covered by the device checks.

## 5. Tooling and docs

- **`scripts/smoke.sh`:**
  - The header says to suspend energd first with `sudo launchctl kill SIGSTOP system/app.energ.energd` and to resume it afterwards with `SIGCONT`. EnerG's Pause doesn't stop the heal, and the heal undoes `adapter off`.
  - If the original limit is below 50, the restore sets 50 and prints a note saying so.
- **Limits redesign spec:**
  - `adapterWasCut()` is called at every heal, not once at start.
  - "Retried up to 3 times" becomes "3 attempts".
  - Remove the stale "Stuck recovery … decided by Task 1 spike" bullet.
  - The `Hardware` port postcondition gets the `adapterCut` throw path.
  - Point its Weak Adapter text to this spec.
- **Base spec:** merge "Sub-80 lowering at a steady %" into the "Sub-80 limits" bullet. The Discharge sections stay under their historical banner.
- **README:** replace the Weak Adapter description with the light-work note.
- **`energd/EngineHost.swift` (~25–26):** rewrap the doc comment.
- **`MacHardware.swift`:** keep the "older build's Discharge" comment. A Mac upgraded from that build is still a real cause.

## 6. Device checks

With energd on this build and AlDente off:

- (a) 30 W charger at the limit: the adapter row shows "30 W" with "light work" below, and keeps it during a Limit Drain (set a limit below the current %).
- (b) 140 W charger: "140 W" while holding, "140 W" with "idle" below during a Limit Drain.
- (c) Lower the limit while charging: the popover shows "Charging" until macOS stops, then "Draining to N %".
- (d) Set a limit below 80 while unplugged, then plug in: `get-limit` shows `CHLT` = the limit, and there's no `lowLimitUnsupported`.
- (e) `scripts/smoke.sh` with energd suspended (SIGSTOP): `adapter off` sticks, and the restore leaves the original limit.
- (f) 66 tests minus the removed ones plus the new ones all pass, and the app builds.

# EnerG Calibration and Limit Check — Design

A Charge Limit below 80 no longer falls back to 80 for good when macOS ignores it for a while.

## Problem

On 2026-10-25 macOS started a battery calibration charge (PowerUI: `ChargingUpForGauging`, "Battery mitigations are in place, MCL will be ignored"). During it, macOS ignores every charge limit and SMC `CHLT` reads off (`energ-smoke get-limit` printed `80 CHLT=off`). EnerG re-set the 60% limit on plug-in, saw it didn't take, and fell back to 80 through `setMCL(80)`. That also overwrote the 60 override. The popover then showed "This Mac doesn't accept limits below 80%. Holding at 80%." until the limit changed or energd restarted.

## Behaviour

- `CHLT` off while a limit is requested and the adapter is plugged in means **Calibration**. EnerG shows a tile, writes nothing and doesn't pulse. No limit is in effect, so the status line shows plain "Charging"/"Not charging". The override stays in place, so macOS applies the limit by itself once calibration ends. A limit write (wake, start, limit change) during Calibration writes the override but skips the pulse while `CHLT` still reads off. Calibration clears the retry state.
- `CHLT` reads a value other than the requested limit: EnerG reports that value as the limit in effect and writes the limit again (override, notify, pulse if needed) 10 min later, then after 20, 40, 80 and 160 min, staying at 160. Only a limit below 80 can be **unsupported**: when it still reads wrong after the first retry, EnerG shows today's tile and stops the timed retries. The override stays in place; a plug-in or limit change starts fresh, and a wake re-asserts the limit.
- `CHLT` equals the requested limit: no tile, and the retry state is cleared.
- Reads within 30 s of a limit write can be stale. They don't change the verdict.
- The retry state also resets on a limit change and on a plug or unplug event.
- Unplugged, paused or topping up: no verdict, no tile.
- Releasing the limit (off, Pause, Top Up) first puts 80 back when the override or `CHLT` is below 80, so System Settings never holds a value it can't show.

## Architecture

| Module | Role | Change |
|---|---|---|
| `LimitCheck` (new, EnerGCore) | Answers "did the requested limit take?" from snapshots. Pure value type, no Hardware. | Owns the verdict, the backoff, the stale-read window and when to write again. |
| `Actuator` | Writes an `Actuation`; keeps the Features whose writes failed and the last limit written. | Asks `LimitCheck` whether to write the limit again. Drops `effectiveLimit` from writes, `limitUnverified` and `needsReverify`. |
| `Engine` | Builds `Status`. | Takes `now: () -> Date` (default `Date.init`). Builds warnings and `effectiveLimit` from the `LimitCheck` verdict. |
| `NativeLimit` | Writes the native limit; below 80 via the override (ADR 0001). | `set` only writes: no `fallBack`, no `setMCL(80)` after a failed check. Returns nothing. |
| `Hardware.setChargeLimit(_:) throws` | | No return value. |
| `BatterySnapshot` | | New `firmwareLimit: Int?` (`CHLT` byte 0; nil when off or unreadable), decoded with `decodeIfPresent`. MacHardware already reads `CHLT` in `snapshot()`. |

`LimitCheck` interface (sketch):

- `mutating func wrote(at: Date)`: a limit write was made.
- `mutating func observe(requested: Int?, snapshot: BatterySnapshot?, now: Date) -> Bool`: updates the verdict and returns true when the limit should be written again now. Unplugged resets the state, so a plug-in starts fresh: no `previous` snapshot needed. A fresh start (plug-in, limit change) also waits the 30 s stale-read window.
- `var verdict: Verdict`: `.none`, `.ok`, `.calibrating`, `.mismatch(Int)`, `.unsupported(Int)` (the value in effect).
- A rewrite marks a limit below 80 as unsupported. At 80 and above a mismatch only retries; it never shows the unsupported tile.

`effectiveLimit` = what the firmware holds: the `CHLT` value when the verdict is `.mismatch` or `.unsupported`, nil when `.calibrating`, else the last limit written successfully (nil when off, paused, topping up or unavailable).

## Copy

- New `Warning.calibrating`. Tile title "Charge Limit paused by macOS". Detail: "macOS is calibrating the battery and ignores charge limits until it's done. EnerG switches back to <limit>% as soon as it can.", with the limit from `settings.chargeLimit`.
- `.lowLimitUnsupported` keeps "This Mac doesn't accept limits below 80%. Holding at 80%."
- `NoticeTile` gains an optional secondary detail line. A `Status` method returns the detail for a warning, so the copy stays in EnerGCore and stays unit-tested.
- `Status.predicted` keeps `.calibrating` while a limit is still requested and drops it otherwise.

## Docs

- CONTEXT.md: add **Calibration**.
- ADR 0001 Consequences: replace "falls back to 80 and warns" with the check-and-retry rule above.

## Testing

TDD with a fake clock:

- `LimitCheck`, on its own:
  - `CHLT` off → calibrating, no rewrite.
  - Mismatch → rewrites at 10 and 20 min, unsupported after the first retry.
  - Match clears the state.
  - Reads within 30 s of a write keep the verdict.
  - A plug event and a limit change reset the state.
  - Unplugged, paused and topping up give no verdict.
- `NativeLimit`: a failed check no longer calls `setMCL(80)`.
- Engine: warnings and `effectiveLimit` come from the verdict.
- `Labels` and `Prediction`.

## Compatibility

The app decodes energd's `Status`. energd runs from inside the app bundle (SMAppService), and both `install.sh` and `get.sh` restart it after replacing the app, so an older app never talks to a newer energd. A newer app talking to an older energd works: `firmwareLimit` is decoded with `decodeIfPresent`.

## Out of scope

- Reading PowerUI's calibration state through private API.
- macOS notifications.

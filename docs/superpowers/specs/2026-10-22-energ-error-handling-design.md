# EnerG Error Handling and At-Limit Charging — Design

Follow-up to `2026-10-21-energ-async-controls-design.md`, from the on-device check.

## Problems found

1. **"Charging" at the limit after Resume / Stop Top Up.** A sample of `CHLT` every 0.25 s showed that for up to ~1 s after a limit is written, the status byte reads `00` (charging) before it settles on `05` (holding), e.g. `[60, 5, 0]` → `[60, 5, 5]` at 60 %. energd's reply is built from the snapshot taken before the write ("Holding"), which agrees with the prediction and ends the settle. The next poll (2 s cadence again) lands in the `00` window and shows "Charging" until the poll after it. Battery watts decay smoothly to 0 over ~2 s: sensor lag, not charging.
2. **Two error tiles** after a give-up ("Helper not reachable: …XPCRichError…" + "change not applied"), and in general: `daemonError` and `actionError` render separately, and most messages append raw `localizedDescription`.
3. **"Waiting for helper…"** sits awkwardly under the battery percentage.

## Design

### At-limit charging
While the native limit is on, a `CHLT` status `00` with the battery at or above the limit (`percent >= CHLT[0]`) means not charging. A real top-off within the same displayed percent then reads "Holding at N%", and the MagSafe LED no longer flashes orange in that window. Other statuses and the fallbacks are unchanged.

### One problem at a time
The popover shows at most one problem notice, chosen as: a dropped change or failed release first (they are about the helper), then the connection (retrying a change, else polls failing), then any other failed click. Retry, like any click, clears a failure. Raw errors go to the system log (`Logger`, subsystem `app.energ`, category `app`), never into the UI.

| Problem | Text (exact) | Button |
|---|---|---|
| Helper unreachable (polls fail) | "Helper not reachable." | — (the existing Retry shows when there is no status yet) |
| Change dropped after the retry window | "Helper not reachable. Your change wasn't applied." | — |
| Change being retried | "Waiting for helper…" (spinner, secondary text) | — |
| Install failed | "Couldn't install the helper." | — (Install Helper stays on the helper tile) |
| `release` failed during uninstall | "Couldn't hand charging back to macOS, so the helper is still installed." | "Uninstall Anyway" |
| Uninstall (unregister) failed | "Couldn't uninstall the helper." | — |
| Launch at Login failed (on or off, incl. the first-run default) | "Couldn't change Launch at Login." | "Open Login Items" |

- A failed click or dropped change clears when the user starts any action. A dropped change also clears once energd answers again, so "not reachable" is never shown while it is reachable.
- The waiting notice sits where the error notices sit, and turns into the dropped-change notice on give-up; the caption under the percentage goes.

## Architecture

| Module | Interface | Seam | Depth rationale | Test surface |
|---|---|---|---|---|
| `Problem` (EnerGCore, new `Problem.swift`) | `enum Problem { installFailed, releaseFailed, uninstallFailed, launchAtLoginFailed, changeNotApplied, waitingForHelper, helperUnreachable }`; `message`; `action: ProblemAction?` (`uninstallAnyway`, `openLoginItems`, each with `title`); `isPending`; `static func shown(failure:connection:) -> Problem?` (order: `changeNotApplied`/`releaseFailed`, connection, other failures) | Pure values next to `Labels.swift` (copy lives in EnerGCore so it is unit-tested) | All copy, buttons and precedence behind one value; without it they spread back across `AppModel` and the view | `ProblemTests` |
| `AppModel` (changed) | Drops `daemonError`, `actionError`, `offersUninstallAnyway`; adds `problem: Problem?` (computed), `resolve(_ ProblemAction)`; private `failure`, `unreachable`, `fail(_:_:)` that logs and sets `failure` | Thin shell | Maps events onto `Problem`; builds no strings | Manual |
| `PopoverView` (changed) | `ProblemTile` replaces `ErrorTiles` in the same three places; `NoticeTile` gains `busy` (spinner icon, secondary text); waiting caption removed | — | — | Manual |
| `BatterySnapshot.isCharging` (EnerGCore, changed) | gains `percent:`; status `00` at or above `CHLT[0]` → false | Existing pure function | Fixes the false "charging" at its source for state, label and LED | `IsChargingTests` |

## Testing
- Unit: `IsChargingTests` (at, above, below the limit with `00`); `ProblemTests` (copy and button per case, precedence, nil when nothing is wrong).
- Manual on device: Resume and Stop Top Up at the limit show no "Charging"; helper stopped during a change shows one waiting notice, then one "Helper not reachable. Your change wasn't applied."; Launch at Login failure (if reproducible) shows the Open Login Items button.

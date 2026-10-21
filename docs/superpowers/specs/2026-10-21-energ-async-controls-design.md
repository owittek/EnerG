# EnerG Async Controls — Design

Make the popover controls (Pause, Top Up, Charge Limit, MagSafe LED) respond instantly and never block, and stop the state line from blipping (e.g. "Paused" → "Charging" → "Holding at 80%"). App and EnerGCore only; energd and the protocol are unchanged.

## Current

- Each click `await`s the XPC reply. A Charge Limit below 80 (set, or re-applied on Resume / Stop Top Up) blocks energd's serial queue for up to ~5 s (override + `CHIE` pulse).
- Tiles read the last confirmed `Status`, so a second click during that wait resends the same request (no-op): Pause → Resume is lost.
- Polls queue behind the slow write.
- For ~3 s after a limit write, `isCharging` can read stale-true, so the state line shows "Charging" at or above the limit before settling.

## Behaviour

1. **Instant:** a click updates the app's *desired* settings immediately; tiles, slider and the state line show the result at once.
2. **Latest wins:** one request in flight. After each reply, the app sends the next field where desired still differs from confirmed, in the order paused → limit → topUp → LED. Intermediate states are skipped; clicks that cancel out send nothing.
3. **Predicted state line:** the popover shows a status predicted from the desired settings and the latest snapshot, using the Engine's rules:
   - Pause → "Paused"; Top Up → "Topping up to 100%".
   - Otherwise, with new limit L (nil when paused, topping up or 100) and battery p: unplugged → "On battery"; p > L → "Draining to L%"; p == L → "Holding at L%"; L−5 ≤ p < L → keeps the charging state from before the click; p < L−5 → "Charging"; L nil → charging while p < 100.
   - L < 80 while `lowLimitUnsupported` is already shown → predict 80.
   - No transitional ("…") labels.
4. **Settle:** the prediction stays until a confirmed status (reply or poll) *agrees* — confirmed settings and Top Up match desired, and confirmed `state` and `stateLabel` equal the prediction — or until 6 s after the queue empties (nothing in flight, nothing left to send). Then the confirmed status shows. Poll every 0.5 s while settling, 2 s otherwise.
5. **Band freeze:** the charging state used for the L−5 ≤ p < L case is taken from the confirmed snapshot at the first click of a settle and kept until it ends.
6. **Rebase:** fields energd changes on its own (Top Up ending on unplug, Pause clearing Top Up) update desired, except a field whose request is queued or in flight. A reply or poll answered before a field's request ran never marks that field done.
7. **Popover closed:** polling stops; the queue keeps sending until empty. On reopen, the last displayed status stays until the first poll sent after the reopen answers; earlier replies are not shown.
8. **Helper unreachable:** on a connection error for a queued change, keep the prediction, show a quiet "Waiting for helper…" line under the state, and retry every 1 s. A click during the retry window replaces the pending change. If still failing 10 s after the first failure: drop desired, show the confirmed status, and show the error tile "Helper not reachable — change not applied." Poll-only failures surface as `daemonError`, as today.
9. **Uninstall:** `release` bypasses the queue and resets it.

## Architecture

| Module | Interface | Seam | Depth rationale | Test surface |
|---|---|---|---|---|
| `ChargeState.derive` (EnerGCore, new) | `static func derive(paused:toppingUp:snapshot:effectiveLimit:) -> ChargeState` | Extracted from `Engine.state()`; Engine and prediction both call it | Keeps prediction and Engine from drifting; every drift is a blip | Existing Engine tests + direct cases |
| `Status.predicted` (EnerGCore, new) | `func predicted(settings:toppingUp:chargingBefore:) -> Status`: keeps snapshot and warnings; rewrites `effectiveLimit`, the snapshot's `isCharging` (band rule) and `state` | Pure function on `Status` | Returns a plain `Status`, so labels and views are unchanged | Table tests: p vs L, band with `chargingBefore` true/false, sub-80 fallback, unplugged, paused, Top Up |
| `Reconciler` (EnerGCore, new value type) | `want(_ Request, now:)`; `nextRequest(now:) -> (Request, Token)?`; `beginPoll() -> Token`; `received(_ Status, _ Token, now:)`; `failed(_ Token, now:) -> .retry \| .gaveUp`; `reopened()`; reads `displayed(now:) -> Status?`, `isSettling`, `settleDeadline`, `waitingForHelper` | In-process; time passed as `now:`; no port | Hides desired/confirmed/in-flight, token ordering (replaces `requestSeq`/`appliedSeq`), rebase, band freeze, settle cap, reopen hold, retry window | Unit tests for every behaviour above, through this interface only |
| `AppModel` (changed) | `status` becomes the displayed status; `change(_ Request)` is sync, fire-and-forget; `waitingForHelper`; a sender task drains `nextRequest` independent of polling; poll interval from `isSettling`; re-reads the display at `settleDeadline`; `release` bypasses and resets the `Reconciler` | Thin shell over XPC, timers and error strings | Shallow on purpose; logic lives in `Reconciler` | Manual |
| `PopoverView` (changed) | Tiles call `model.change(...)` based on the displayed status; slider clears `draftLimit` on release; "Waiting for helper…" line under the state | — | — | Manual |

`DaemonClient` gets no port: one adapter, and the logic it would help test lives in `Reconciler`.

## Testing

- Unit (EnerGCore, Swift Testing): `ChargeState.derive`, `Status.predicted`, and `Reconciler` scenarios — resume at 85% / limit 80 with a stale "Charging" reply; resume with limit 60 (slow reply); Pause → Resume → Pause while in flight; Top Up then stop; 80 → 60 on a Mac that rejects < 80 (one correction); close/reopen with a stale reply; band with stale-true reply; poll answered before a queued request; short (3 s) and long (> 10 s) helper outage; click during retry.
- Manual on device: each control responds instantly, repeated clicks work during a slow limit write, no "Charging" blip on Resume / Stop Top Up, popover closed mid-change, helper stopped (`launchctl kickstart` / bootout) during a change.

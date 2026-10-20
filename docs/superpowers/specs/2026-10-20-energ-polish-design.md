# EnerG — Polish round 1 (post-v1)

Date: 2026-10-20
Status: approved (brainstorming)
Base: [EnerG design](2026-10-20-energ-design.md) · Glossary: [CONTEXT.md](../../../CONTEXT.md)

## Purpose

Fix the known issues left after v1 (handoff items 1–4, 6–14, 16–18). None blocks daily use. All of them ship in one round.

Out of scope:
- Item 5 (native limit stays as last set after Login Items off): by design.
- Item 15 (`scripts/smoke.sh` restore robustness): parked.

## New platform facts (probe, 2026-10-20, Mac17,8)

These get added to the base spec's "Verified platform facts".

- **USB-C charging:** `CHIE`=`08` cuts USB-C input too, on either port. macOS then shows "Battery Power" and `ExternalConnected` = No. `AC-W` stays > 0 while it is cut.
- **USB-C and MagSafe both attached:** `CHIE` cuts both inputs. `AC-W` stays > 0 while any charger is attached, and goes to -1 at once when the last one is unplugged. `AdapterDetails.Watts` reports whichever input macOS picked, and changes when one is pulled.
- **LED without MagSafe:** `ACLC` writes succeed with USB-C only, with no visible effect. So there is no false "LED unavailable".
- **Registry cadence:** on battery power, including while `CHIE` cuts the adapter, the `AppleSmartBattery` registry refreshes only every ~60 s (`UpdateTime`). `InstantAmperage`, and so `batteryWatts`, keeps the last value from before the cut for up to a minute. `PSTR` (SMC) is live.

## Changes

### Engine — safety

1. **Unstick when the prior adapter state is unknown.**
   - The native-limit re-apply (`setChargeLimit(nil)`, then `setChargeLimit(limit)`) runs after a successful adapter-on when **both** hold:
     - `applied?.adapterEnabled != true`, i.e. off or unknown;
     - the battery is above a set desired limit.
   - This covers `.start` (crash or relaunch mid-Discharge) and `.didWake`.
   - Cost: one extra limit off/on per start or wake above the limit. The base spec says off/on restores AC at once and AC then holds at the limit, so it is harmless.
   - The base spec's "Native-limit unstick" rule is updated to match.
2. **A failed re-apply doesn't latch.**
   - If `setChargeLimit(nil)` succeeds and `setChargeLimit(limit)` throws:
     - the Engine records `applied.chargeLimit = nil` (the true hardware state);
     - it does not mark `.chargeLimit` unavailable.
   - The next evaluate (≤ 30 s) sees a changed limit and writes it through the normal path. That path latches unavailable if it fails again.
   - If `setChargeLimit(nil)` itself throws, the native limit is unchanged and normal latching applies.
3. **Unplug ends a Discharge.**
   - `BatterySnapshot` gains a `Bool` that is true when `adapterConnected` was read from `AC-W`. Name it in the plan, e.g. `plugSensed`.
   - `MacHardware` sets it; `FakeHardware` defaults it to true.
   - New rule in `Policy.update`: when the flag is true and `!adapterConnected`, a running Discharge ends (`dischargeTarget = nil`), without setting suppression.
     - On replug, Auto-Discharge re-arms if the battery is above the limit.
     - A manual target below the limit is not resumed.
   - On the `ExternalConnected` fallback, the flag is false and the rule doesn't apply, because a cut reads as unplugged there and would loop.
   - This also covers item 8: a Discharge requested while unplugged on an `AC-W` Mac is dropped in the same evaluate, before any cut. The F3 guard in `perform(.discharge)` stays for the fallback path.
4. **Honest "Uninstall Anyway".**
   - New notice text in `AppModel`: "Uninstall Anyway removes the helper without handing charging back first. If the helper is still running, it restores the adapter and LED as it stops; if not, they may stay as last set. The native Charge Limit may stay on."
   - The README Uninstall section and the base spec's Uninstall error-handling line are reworded to match.

### Engine / Policy — state

5. **Weak Adapter blip (item 6).**
   - Only `.tick` counts a Weak Adapter sample. `.powerChanged` can only reset the count, as other events already do.
   - The first tick after a Discharge ends, for any reason, does not count either. A Session flag is set when `dischargeTarget` goes from non-nil to nil, and cleared by the next tick.
   - Warning latency becomes 60–90 s. It is warning-only.
   - The base spec's Weak Adapter definition is updated.
6. **Pause while unreadable (item 7).** The unreadable path in `Engine.evaluate` applies the same session reset as `Policy.update` does when paused: Discharge, Top Up, suppression and weak count all cleared. Extract it as one shared helper.

### Power display (item 10)

7. **Live battery power.**
   - Probe the candidate SMC keys unprivileged: `PPBR`, and `B0AC` × `B0AV`. Do it on AC, while cut, and unplugged.
   - **A key tracks reality:**
     - **On AC:** its sign and magnitude roughly match the registry.
     - **While cut or unplugged:** it changes within seconds while the registry is stale.
   - If one does, `MacHardware` reads `batteryWatts` from it and falls back to the registry when the key is missing.
   - **Otherwise:** keep the registry. When macOS reports no external power (`ExternalConnected` = No) but `batteryWatts > 0`, show "—" for the battery flow until the registry refreshes.
   - The probe result goes into the base spec's facts.

### App (item 9)

8. Uninstall is enabled while the helper is `.requiresApproval`. It only unregisters, with no `release`, because the daemon isn't running then.
9. `setLimit` is sent only when the value at the end of the drag differs from `status.settings.chargeLimit`.
10. Toggle tile actions read `model.status` when tapped, not the `status` captured at render.
11. A failure to set the launch-at-login default on first launch sets `actionError` instead of being swallowed.
12. `DaemonClient` cancels the `XPCSession` when `send` throws.
13. The AlDente process scan runs off the main actor (detached task). It runs when the popover opens and then every 10 s, not every 2 s.

### Robustness

14. **Lenient Settings decoding (item 11).** `Settings` gets a custom `init(from:)`. Each field is `try? decodeIfPresent`, falling back to its default, so a missing or invalid field resets only itself. `SettingsStore`'s limit validation stays.
15. **XPC decoding (item 12).** energd switches to the untyped incoming-message handler and decodes `Request` manually.
   - An undecodable message is logged and gets no reply; the client sees an error.
   - It never crashes energd.
16. **Sleep assertion (item 13).** `MacHardware.setPreventSleep` checks the `IOPMAssertionCreateWithName` return. On failure it logs and leaves the id at 0.
   - No protocol change: if the Mac sleeps, `willSleep` already ends the Discharge safely.

### Tooling, tests, docs

17. **`scripts/install.sh` (item 14).** Full xcodebuild output goes to `build/xcodebuild.log`.
   - **On failure:** print the `error:` lines and the log path, then exit non-zero.
   - **On success:** keep the current short tail.
18. **`energ-smoke` (item 16).**
   - `get-limit` reports the real PowerUI return code.
   - `limit N` rejects N outside 0…100 with the usage text, instead of trapping.
19. **Tests (item 17).**
   - `startClearsAStaleDischarge` asserts the full write sequence.
   - New: cancel-suppression clears at or below the limit, without an unplug.
   - New: an interleaved non-weak sample resets the Weak Adapter count.
   - New: unavailable features are not re-attempted, while the wake re-assert path retries.
   - `SettingsStoreTests` remove their temp dirs.
   - Every Engine/Policy change above comes with tests written first.
20. **README (item 18).** State that contributors must replace the committed `DEVELOPMENT_TEAM` (`XG5GU82KF7`) with their own team. Add the USB-C facts to the README's hardware notes.

## Verification

- `swift test --package-path Packages/EnerGKit`: all tests pass, old and new.
- `scripts/install.sh` builds and installs.
- **On-device checks.** The user runs the sudo parts; the agent samples state unprivileged.
  - **Item 1:** start a Discharge above the limit, then `sudo kill -9` energd. After the relaunch, AC returns within seconds.
  - **Item 3:** with the adapter cut during a Discharge, unplug every charger. The Discharge ends, and on replug Auto-Discharge resumes if the battery is above the limit.
  - **Item 6:** after a Discharge ends, there is no Weak Adapter warning.
  - **Item 10:** the battery flow is correct within seconds of a cut, or shows "—".

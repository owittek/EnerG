# EnerG Footer Polish — Design

Polish the popover footer's "Uninstall Helper" and "Quit EnerG" buttons. View-only change in `EnerG/PopoverView.swift`; `AppModel` is untouched.

## Current

`Footer` is an `HStack` of two `.borderless` text buttons in `.callout`. Uninstall runs on one click with no confirmation and no progress; it is shown disabled when the helper is neither `.enabled` nor `.requiresApproval`.

## Design

### Layout
- A `Divider` separates the footer from the tiles above.
- Two full-width menu-style rows stacked vertically:
  - `trash` — "Uninstall Helper"
  - `power` — "Quit EnerG", with "⌘Q" right-aligned in secondary style.
- New `FooterRowStyle: ButtonStyle`: icon + label in `.callout`, primary text colour, full-width hit area, subtle `.quaternary` background on hover or press, small corner radius (~6). Not accent-coloured — accent means "toggle on" in the tiles.

### Uninstall flow
1. **Visibility:** the Uninstall row is shown only when `model.helper` is `.enabled` or `.requiresApproval`; otherwise hidden (not disabled).
2. **Inline confirm:** clicking the row replaces it in place with the text "Uninstall helper? Charging goes back to macOS." and two buttons: Cancel (`.keyboardShortcut(.cancelAction)`, Esc) and Uninstall (destructive role, red). No `confirmationDialog`/alert — a sheet on the `MenuBarExtra(.window)` panel gets clipped and an app-modal alert can steal focus and dismiss the panel.
3. **In progress:** on confirm, the area shows a small `ProgressView` + "Uninstalling…", non-interactive, while `await model.uninstallHelper()` runs; it then returns to the idle row.
4. **Errors:** unchanged — they surface via `ErrorTiles` (including "Uninstall Anyway").
- State lives in `Footer` as local `@State` (idle / confirming / uninstalling).

### Quit
- Same row style; `.keyboardShortcut("q")` on the button. Behaviour unchanged (the helper keeps enforcing after quit).

## Testing
View-only; no unit tests. Build, then verify manually: hover highlight on both rows; confirm → Uninstall; confirm → Cancel; confirm → Esc; spinner during uninstall; Uninstall row hidden when the helper is not registered; ⌘Q quits.

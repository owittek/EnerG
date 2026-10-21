# EnerG Footer Polish — Design

Polish the popover footer's "Uninstall Helper" and "Quit EnerG" buttons. View-only change in `EnerG/PopoverView.swift`; `AppModel` is untouched.

## Current

`Footer` is an `HStack` of two `.borderless` text buttons in `.callout`. Uninstall runs on one click with no confirmation and no progress; it is shown disabled when the helper is neither `.enabled` nor `.requiresApproval`.

## Design

### Layout
- Two columns as before: "Uninstall Helper" (`trash`) left, "Quit EnerG" (`power`, "⌘Q" in secondary style) right.
- New `FooterButtonStyle: ButtonStyle`: borderless, `.callout`, subtle `.quaternary` background on hover or press, ~6 corner radius. Not accent-coloured — accent means "toggle on" in the tiles.

### Uninstall flow (two-click arm; chosen over an inline prompt and mini tiles via an HTML prototype)
1. **Visibility:** the Uninstall button is shown only when `model.helper` is `.enabled` or `.requiresApproval`; otherwise hidden (not disabled).
2. **Arm:** first click turns the button into red "Confirm Uninstall". It reverts after 3 s, on Esc, or when the mouse leaves it. No dialog/alert/filled buttons — a sheet on the `MenuBarExtra(.window)` panel gets clipped, an alert can dismiss the panel, and prominent buttons render washed out while the panel isn't key.
3. **In progress:** second click shows a small `ProgressView` + "Uninstalling…" in place while `await model.uninstallHelper()` runs, then returns to idle. Quit stays put; no layout shift.
4. **Errors:** unchanged — they surface via `ErrorTiles` (including "Uninstall Anyway").
- State lives in `Footer` as local `@State` (idle / armed / uninstalling).

### Quit
- Same button style; `.keyboardShortcut("q")` on the button. Behaviour unchanged (the helper keeps enforcing after quit).

## Testing
View-only; no unit tests. Build, then verify manually: hover highlight on both buttons; arm → reverts after 3 s / Esc / mouse leave; arm → click → spinner during uninstall; Uninstall hidden when the helper is not registered; ⌘Q quits.

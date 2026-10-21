# EnerG Footer Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the popover footer's plain "Uninstall Helper" / "Quit EnerG" text buttons with menu-style rows, inline uninstall confirmation, progress feedback and ⌘Q.

**Architecture:** View-only change in `EnerG/PopoverView.swift`: a new private `FooterRowStyle` button style and a rewritten `Footer` holding a local idle/confirming/uninstalling phase. `AppModel` is untouched.

**Tech Stack:** SwiftUI (macOS), XcodeGen + xcodebuild.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-21-energ-footer-polish-design.md`.
- Confirm copy, verbatim: "Uninstall helper? Charging goes back to macOS."
- No `confirmationDialog` / alert (the `MenuBarExtra(.window)` panel clips sheets and alerts can dismiss it).
- Hover highlight is `.quaternary`, never the accent colour.
- Uninstall row hidden (not disabled) unless `model.helper` is `.enabled` or `.requiresApproval`.
- Quit behaviour unchanged; only adds `.keyboardShortcut("q")`.
- **App build check:** `xcodegen generate && xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug -derivedDataPath build -allowProvisioningUpdates build 2>&1 | grep -E "error:|warning: .*EnerG|BUILD (SUCCEEDED|FAILED)"`. Expected: `** BUILD SUCCEEDED **`.
- No commit attribution trailers.

---

### Task 1: Footer rows, inline confirm, progress, ⌘Q

**Files:**
- Modify: `EnerG/PopoverView.swift:278-292` (the `Footer` struct; add `FooterRowStyle` right above it)

**Interfaces:**
- Consumes: `AppModel.helper: SMAppService.Status`, `AppModel.uninstallHelper(skipRelease:) async` (existing).
- Produces: nothing used elsewhere (all `private`).

No unit test: view-only, the project has no UI test target. Verification is the build check plus the manual checklist.

- [ ] **Step 1: Replace the `Footer` struct** (lines 278-292) with:

```swift
/// Menu-style footer row: full width, subtle highlight on hover or press.
private struct FooterRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering || configuration.isPressed ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 6))
                .contentShape(.rect)
                .onHover { hovering = $0 }
        }
    }
}

private struct Footer: View {
    let model: AppModel
    @State private var phase = Phase.idle

    private enum Phase { case idle, confirming, uninstalling }

    private var canUninstall: Bool { model.helper == .enabled || model.helper == .requiresApproval }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Divider().padding(.bottom, 4)
            if canUninstall { uninstall }
            Button { NSApplication.shared.terminate(nil) } label: {
                HStack {
                    rowLabel("Quit EnerG", "power")
                    Spacer()
                    Text("⌘Q").foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(FooterRowStyle())
        .font(.callout)
        .onChange(of: model.helper) { if phase == .confirming { phase = .idle } }
    }

    @ViewBuilder private var uninstall: some View {
        switch phase {
        case .idle:
            Button { phase = .confirming } label: { rowLabel("Uninstall Helper", "trash") }
        case .confirming:
            VStack(alignment: .leading, spacing: 6) {
                Text("Uninstall helper? Charging goes back to macOS.")
                HStack {
                    Spacer()
                    Button("Cancel") { phase = .idle }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                    Button("Uninstall", role: .destructive) {
                        phase = .uninstalling
                        Task {
                            await model.uninstallHelper()
                            phase = .idle
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        case .uninstalling:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Uninstalling…")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
    }

    /// Fixed-width icon so the row titles line up.
    private func rowLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 16)
            Text(title)
        }
    }
}
```

- [ ] **Step 2: Run the App build check** (Global Constraints). Expected: `** BUILD SUCCEEDED **`, no EnerG warnings.

- [ ] **Step 3: Manual check** — `scripts/install.sh`, open the popover:
  - Hover highlights each row in subtle grey.
  - Uninstall → confirm text shown; Cancel returns to the row; Esc returns to the row (and doesn't close the panel first — if it does, note it).
  - Uninstall → Uninstall shows spinner + "Uninstalling…", then the Helper-required tile appears and the Uninstall row is gone.
  - ⌘Q with the panel open quits.

- [ ] **Step 4: Commit**

```bash
git add EnerG/PopoverView.swift
git commit -m "feat: menu-style footer rows with inline uninstall confirm and ⌘Q"
```

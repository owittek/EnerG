import SwiftUI
import ServiceManagement
import EnerGCore

struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.helper != .enabled {
                HelperTile(model: model)
                ErrorTiles(model: model)
            } else if let status = model.status {
                BatteryTile(status: status, model: model)
                NoticeTiles(status: status, model: model)
                ControlGrid(status: status, model: model)
                PowerFlowTile(status: status)
            } else if model.daemonError != nil || model.actionError != nil {
                ErrorTiles(model: model)
                Button("Retry") { Task { await model.refresh() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            Footer(model: model)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }
}

// MARK: - Tile primitives

/// Rounded Control Center–style module; highlighted tiles use the accent colour.
private struct TileBackground: ViewModifier {
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                        in: .rect(cornerRadius: 14))
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
    }
}

private extension View {
    func tile(highlighted: Bool = false) -> some View { modifier(TileBackground(highlighted: highlighted)) }
}

/// A tile that toggles on click; `isOn` highlights it.
private struct ToggleTile: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isOn: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.title3).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).opacity(0.8).lineLimit(1)
                }
            }
            .tile(highlighted: isOn)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

private struct NoticeTile: View {
    let text: String
    let symbol: String
    let tint: Color
    /// Optional button under the text.
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.callout)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle { Button(actionTitle, action: action) }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .tile()
    }
}

// MARK: - Sections

private struct HelperTile: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Helper required", systemImage: "lock.shield").font(.headline)
            if model.helper == .requiresApproval {
                Text("Allow EnerG in System Settings → General → Login Items.").font(.callout)
                Button("Open Login Items") { HelperInstaller.openApproval() }
            } else {
                Text("EnerG needs a privileged helper to control charging.").font(.callout)
                Button("Install Helper") { model.installHelper() }
            }
        }
        .tile()
    }
}

private struct BatteryTile: View {
    let status: Status
    let model: AppModel
    /// Slider value while dragging; sent as one setLimit when the drag ends.
    @State private var draftLimit: Double?

    private var limit: Double { draftLimit ?? Double(status.settings.chargeLimit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(status.snapshot.map { "\($0.percent)%" } ?? "—")
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                Text(status.stateLabel).foregroundStyle(.secondary)
                Spacer()
            }
            if status.state == .limitDrain {
                Text("macOS runs the Mac from the battery until it's back at the limit.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Charge Limit")
                Spacer()
                Text("\(Int(limit))%").monospacedDigit()
            }
            .font(.callout)
            Slider(value: Binding(get: { limit }, set: { draftLimit = $0 }), in: 50...100, step: 5,
                   onEditingChanged: { editing in
                       guard !editing, let draft = draftLimit else { return }
                       guard Int(draft) != status.settings.chargeLimit else {
                           draftLimit = nil
                           return
                       }
                       Task {
                           await model.perform(.setLimit(Int(draft)))
                           draftLimit = nil
                       }
                   })
                   .disabled(status.state == .paused || status.isUnavailable(.chargeLimit))
        }
        .tile()
    }
}

/// Warnings, AlDente and errors, shown between the Charge Limit and the controls.
private struct NoticeTiles: View {
    let status: Status
    let model: AppModel

    var body: some View {
        ForEach(status.warnings, id: \.self) { warning in
            NoticeTile(text: warning.label, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        if model.alDenteRunning {
            NoticeTile(text: "AlDente (or its helper) is running and may override EnerG.",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        ErrorTiles(model: model)
    }
}

private struct ErrorTiles: View {
    let model: AppModel

    var body: some View {
        if let error = model.daemonError {
            NoticeTile(text: error, symbol: "xmark.octagon.fill", tint: .red)
        }
        if let error = model.actionError {
            NoticeTile(text: error, symbol: "xmark.octagon.fill", tint: .red,
                       actionTitle: model.offersUninstallAnyway ? "Uninstall Anyway" : nil) {
                Task { await model.uninstallHelper(skipRelease: true) }
            }
        }
    }
}

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

/// Adapter → Mac ↔ Battery with live watts.
private struct PowerFlowTile: View {
    let status: Status

    var body: some View {
        if let snapshot = status.snapshot {
            HStack(spacing: 6) {
                node("powerplug.fill", adapterText(snapshot))
                Image(systemName: "arrow.right")
                    .foregroundStyle(adapterFlowing(snapshot) ? .primary : .tertiary)
                node("laptopcomputer", snapshot.systemWatts.map { String(format: "%.0f W", $0) } ?? "—")
                Image(systemName: batteryArrow(snapshot))
                    .foregroundStyle(abs(snapshot.batteryWatts) < 0.5 ? .tertiary : .primary)
                node("battery.75percent", String(format: "%+.0f W", snapshot.batteryWatts))
            }
            .frame(maxWidth: .infinity)
            .tile()
        }
    }

    private func node(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3)
            Text(text).font(.caption.monospacedDigit()).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// During a Limit Drain the adapter is attached but idle: macOS runs the Mac from the battery.
    private func adapterFlowing(_ snapshot: BatterySnapshot) -> Bool {
        snapshot.adapterConnected && status.state != .limitDrain
    }

    private func adapterText(_ snapshot: BatterySnapshot) -> String {
        guard snapshot.adapterConnected else { return "Unplugged" }
        let rated = snapshot.adapterWatts.map { "\($0) W" } ?? "Connected"
        return status.state == .limitDrain ? "\(rated) · idle" : rated
    }

    /// Mac → battery while charging, battery → Mac while draining.
    private func batteryArrow(_ snapshot: BatterySnapshot) -> String {
        if snapshot.batteryWatts > 0.5 { return "arrow.right" }
        if snapshot.batteryWatts < -0.5 { return "arrow.left" }
        return "minus"
    }
}

private struct Footer: View {
    let model: AppModel

    var body: some View {
        HStack {
            Button("Uninstall Helper") { Task { await model.uninstallHelper() } }
                .disabled(model.helper != .enabled && model.helper != .requiresApproval)
            Spacer()
            Button("Quit EnerG") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 4)
    }
}

// MARK: - Copy

extension Status {
    /// The Engine stopped writing this Feature after a failed hardware write.
    func isUnavailable(_ feature: Feature) -> Bool { warnings.contains(.unavailable(feature)) }
}

extension Status {
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
}

extension ChargeState {
    var label: String {
        switch self {
        case .charging: "Charging"
        case .atLimit: "Holding at limit"
        case .limitDrain: "Draining to limit"
        case .toppingUp: "Topping up to 100%"
        case .paused: "Paused"
        case .onBattery: "On battery"
        case .unknown: "Battery unreadable"
        }
    }
}

extension Warning {
    var label: String {
        switch self {
        case .weakAdapter: "Weak Adapter: the battery is draining while plugged in."
        case .lowLimitUnsupported: "This Mac doesn't accept limits below 80%. Holding at 80%."
        case .unavailable(let feature): "\(feature.label) is unavailable on this Mac."
        case .batteryUnreadable: "Can't read the battery state."
        }
    }
}

extension Feature {
    var label: String {
        switch self {
        case .chargeLimit: "Charge Limit"
        case .led: "MagSafe LED control"
        }
    }
}

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

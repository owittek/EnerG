/// Popover copy derived from a Status. Kept here, not in the app, so it is unit-tested.
extension ChargeState {
    public var label: String {
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

extension Status {
    /// The state line under the battery %. "At limit" covers the firmware band below the limit too,
    /// where macOS doesn't charge until the battery drops `NativeLimit.firmwareBand` points under it.
    public var stateLabel: String {
        switch state {
        case .limitDrain:
            return effectiveLimit.map { "Draining to \($0)%" } ?? state.label
        case .atLimit:
            guard let limit = effectiveLimit, let percent = snapshot?.percent else { return "Not charging" }
            if percent >= limit { return "Holding at \(limit)%" }
            let resume = limit - NativeLimit.firmwareBand
            return percent >= resume ? "Not charging · resumes below \(resume)%" : "Not charging"
        default:
            return state.label
        }
    }

    /// The text under the adapter icon: its rating, or its plug state when the rating is unknown.
    public var adapterLabel: String {
        guard let snapshot else { return "—" }
        guard snapshot.adapterConnected else { return "Unplugged" }
        return snapshot.adapterWatts.map { "\($0) W" } ?? "Connected"
    }
}

extension Warning {
    public var label: String {
        switch self {
        case .calibrating: "Charge Limit paused by macOS"
        case .lowLimitUnsupported: "This Mac doesn't accept limits below 80%. Holding at 80%."
        case .unavailable(let feature): "\(feature.label) is unavailable on this Mac."
        case .batteryUnreadable: "Can't read the battery state."
        }
    }
}

extension Feature {
    public var label: String {
        switch self {
        case .chargeLimit: "Charge Limit"
        case .led: "MagSafe LED control"
        }
    }
}

extension LEDMode {
    public var label: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off"
        }
    }

    /// Click order on the LED tile.
    public var next: LEDMode {
        switch self {
        case .auto: .off
        case .off: .auto
        }
    }
}

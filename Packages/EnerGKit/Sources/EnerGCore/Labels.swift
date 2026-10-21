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
    /// Below this rating an adapter is a Weak Adapter: enough for light work, not for sustained load.
    public static let weakAdapterBelowWatts = 50

    /// The state line under the battery %. "At limit" covers the firmware band below the limit too,
    /// where macOS doesn't charge until the battery drops 5 points under it.
    public var stateLabel: String {
        switch state {
        case .limitDrain:
            return effectiveLimit.map { "Draining to \($0)%" } ?? state.label
        case .atLimit:
            guard let limit = effectiveLimit, let percent = snapshot?.percent else { return "Not charging" }
            if percent >= limit { return "Holding at \(limit)%" }
            return percent >= limit - 5 ? "Not charging · resumes below \(limit - 5)%" : "Not charging"
        default:
            return state.label
        }
    }

    /// The text under the adapter icon: its rating, plus "light work" for a Weak Adapter (also during a Limit
    /// Drain) or "idle" during a Limit Drain, when macOS runs the Mac from the battery.
    public var adapterLabel: String {
        guard let snapshot else { return "—" }
        guard snapshot.adapterConnected else { return "Unplugged" }
        guard let watts = snapshot.adapterWatts else { return "Connected" }
        if watts < Self.weakAdapterBelowWatts { return "\(watts) W · light work" }
        return state == .limitDrain ? "\(watts) W · idle" : "\(watts) W"
    }
}

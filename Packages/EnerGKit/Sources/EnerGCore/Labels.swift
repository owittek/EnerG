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

    /// The text under the adapter icon: its rating, or its plug state when the rating is unknown.
    public var adapterLabel: String {
        guard let snapshot else { return "—" }
        guard snapshot.adapterConnected else { return "Unplugged" }
        return snapshot.adapterWatts.map { "\($0) W" } ?? "Connected"
    }
}

extension Status {
    /// The status energd is expected to report once `settings` and `toppingUp` are applied, from this status's
    /// snapshot and warnings. While plugged in and not paused, the snapshot's `isCharging` is re-derived from the new
    /// limit (100 when there is none): off at or above it, `chargingBefore` in the firmware's 5-point band below it,
    /// on further below. A limit below 80 is predicted as 80 once `lowLimitUnsupported` has been reported.
    public func predicted(settings: Settings, toppingUp: Bool, chargingBefore: Bool) -> Status {
        let plugged = snapshot?.adapterConnected ?? true
        let topUp = toppingUp && !settings.paused && plugged
        let requested: Int? = settings.paused || topUp || settings.chargeLimit >= 100 ? nil : settings.chargeLimit
        var effective = requested
        if let limit = requested, limit < NativeLimit.powerUIMinimum, warnings.contains(.lowLimitUnsupported) {
            effective = NativeLimit.powerUIMinimum
        }
        if warnings.contains(.unavailable(.chargeLimit)) { effective = nil }
        var newWarnings = warnings.filter { $0 != .lowLimitUnsupported }
        if let effective, let requested, effective > requested { newWarnings.insert(.lowLimitUnsupported, at: 0) }
        var battery = snapshot
        if var s = battery, s.adapterConnected, !settings.paused {
            let ceiling = effective ?? 100
            s.isCharging = s.percent >= ceiling ? false : s.percent >= ceiling - 5 ? chargingBefore : true
            battery = s
        }
        return Status(state: .derive(paused: settings.paused, toppingUp: topUp, snapshot: battery,
                                     effectiveLimit: effective),
                      settings: settings, snapshot: battery, effectiveLimit: effective, toppingUp: topUp,
                      warnings: newWarnings)
    }
}

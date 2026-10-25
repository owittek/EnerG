extension Status {
    /// The status energd is expected to report once `settings` and `toppingUp` are applied, from this status's
    /// snapshot and warnings. While plugged in and not paused, the snapshot's `isCharging` is re-derived from the new
    /// limit (100 when there is none): off at or above it, `chargingBefore` in the firmware's 5-point band below it,
    /// on further below. During Calibration the snapshot is kept as is: macOS charges past any limit.
    /// A limit below 80 is predicted as 80 once `lowLimitUnsupported` has been reported.
    public func predicted(settings: Settings, toppingUp: Bool, chargingBefore: Bool) -> Status {
        let plugged = snapshot?.adapterConnected ?? true
        let topUp = toppingUp && !settings.paused && plugged
        let requested = Policy.requestedLimit(settings, paused: settings.paused, toppingUp: topUp)
        // macOS ignores every limit during Calibration, whatever the new one; it ends on its own.
        let calibrating = requested != nil && plugged && warnings.contains(.calibrating)
        var effective = requested
        if let limit = requested, limit < NativeLimit.powerUIMinimum, warnings.contains(.lowLimitUnsupported) {
            effective = NativeLimit.powerUIMinimum
        }
        if warnings.contains(.unavailable(.chargeLimit)) { effective = nil }
        var newWarnings = warnings.filter { $0 != .lowLimitUnsupported && $0 != .calibrating }
        if Policy.lowLimitUnsupported(effective: effective, requested: requested) {
            newWarnings.insert(.lowLimitUnsupported, at: 0)
        }
        if calibrating { newWarnings.insert(.calibrating, at: 0) }
        var battery = snapshot
        if var s = battery, s.adapterConnected, !settings.paused, !calibrating {
            let ceiling = effective ?? 100
            let resume = ceiling - NativeLimit.firmwareBand
            s.isCharging = s.percent >= ceiling ? false : s.percent >= resume ? chargingBefore : true
            battery = s
        }
        return Status(state: .derive(paused: settings.paused, toppingUp: topUp, snapshot: battery,
                                     effectiveLimit: effective),
                      settings: settings, snapshot: battery, effectiveLimit: effective, toppingUp: topUp,
                      warnings: newWarnings)
    }
}

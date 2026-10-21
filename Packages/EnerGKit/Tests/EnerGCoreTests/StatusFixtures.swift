@testable import EnerGCore

/// A Status as energd reports it, with the state and effective limit the Engine would derive.
func reported(_ settings: Settings = Settings(), percent: Int = 85, charging: Bool = false, toppingUp: Bool = false,
              plugged: Bool = true, warnings: [Warning] = []) -> Status {
    let active = toppingUp && !settings.paused && plugged
    let limit: Int? = settings.paused || active || settings.chargeLimit >= 100 ? nil : settings.chargeLimit
    let effective = warnings.contains(.lowLimitUnsupported) ? limit.map { max($0, 80) } : limit
    let snapshot = BatterySnapshot(percent: percent, isCharging: charging, adapterConnected: plugged,
                                   adapterWatts: 96, batteryWatts: 0, systemWatts: 10)
    return Status(state: .derive(paused: settings.paused, toppingUp: active, snapshot: snapshot,
                                 effectiveLimit: effective),
                  settings: settings, snapshot: snapshot, effectiveLimit: effective, toppingUp: active,
                  warnings: warnings)
}

/// Runtime state the Engine keeps between events (not persisted).
struct Session: Equatable {
    /// Set while a Discharge runs.
    var dischargeTarget: Int?
    var toppingUp = false
    /// Blocks Auto-Discharge after the user cancels one; cleared on unplug or at/below the limit.
    var autoSuppressed = false
    var weakSamples = 0
    var unavailable: Set<Feature> = []
    var sleeping = false
    var lidClosed = false
    /// Set by `.release` (before uninstall): acts exactly like Pause but is never persisted, so a
    /// reinstall starts with the user's real settings. Cleared by `setPaused` and `.start`.
    var released = false

    var canStartDischarge: Bool { !unavailable.contains(.discharge) && !sleeping && !lidClosed }
}

/// What the hardware should look like right now.
struct Actuation: Equatable {
    var chargeLimit: Int?
    var adapterEnabled: Bool
    var led: LEDState
    var preventSleep: Bool

    /// Stock macOS behaviour: used for Pause and release.
    static let released = Actuation(chargeLimit: nil, adapterEnabled: true, led: .system, preventSleep: false)
}

enum Policy {
    /// Pause, or released before uninstall.
    static func isPaused(_ settings: Settings, _ s: Session) -> Bool { settings.paused || s.released }

    /// Advances the session for a fresh snapshot: ends a Discharge, Top Up and suppression on unplug,
    /// ends a finished Discharge, starts Auto-Discharge, and tracks Weak Adapter samples.
    /// `countsWeakSample`: only periodic readings (tick, power change) count towards a Weak Adapter;
    /// other events can only reset the count.
    static func update(settings: Settings, snapshot: BatterySnapshot, countsWeakSample: Bool, session s: inout Session) {
        if isPaused(settings, s) {
            s.dischargeTarget = nil
            s.toppingUp = false
            s.autoSuppressed = false
            s.weakSamples = 0
            return
        }
        // Unplugged mid-Discharge. Only trusted from AC-W: on the fallback a cut itself reads as unplugged.
        if s.dischargeTarget != nil, snapshot.plugSensed, !snapshot.adapterConnected {
            s.dischargeTarget = nil
        }
        if s.dischargeTarget == nil && !snapshot.adapterConnected {
            s.toppingUp = false
            s.autoSuppressed = false
        }
        if let target = s.dischargeTarget, snapshot.percent <= target {
            s.dischargeTarget = nil
        }
        if snapshot.percent <= settings.chargeLimit {
            s.autoSuppressed = false
        }
        if s.dischargeTarget == nil, s.canStartDischarge, !s.toppingUp, !s.autoSuppressed,
           settings.autoDischarge, snapshot.adapterConnected, snapshot.percent > settings.chargeLimit {
            s.dischargeTarget = settings.chargeLimit
        }
        let weak = s.dischargeTarget == nil && snapshot.adapterConnected && snapshot.batteryWatts < 0
        if !weak {
            s.weakSamples = 0
        } else if countsWeakSample {
            s.weakSamples += 1
        }
    }

    /// Derives the desired hardware state; no side effects.
    static func actuation(settings: Settings, snapshot: BatterySnapshot, session s: Session) -> Actuation {
        if isPaused(settings, s) { return .released }
        let discharging = s.dischargeTarget != nil
        let limit: Int? = (s.toppingUp || settings.chargeLimit >= 100) ? nil : settings.chargeLimit
        return Actuation(chargeLimit: limit,
                         adapterEnabled: !discharging,
                         led: led(settings.ledMode, snapshot, discharging: discharging),
                         preventSleep: discharging)
    }

    private static func led(_ mode: LEDMode, _ snapshot: BatterySnapshot, discharging: Bool) -> LEDState {
        if discharging { return mode == .blink ? .blinkSlow : .off }
        if !snapshot.adapterConnected { return .system }
        if mode == .off { return .off }
        return snapshot.isCharging ? .orange : .green
    }
}

/// Runtime state the Engine keeps between events (not persisted).
struct Session: Equatable {
    var toppingUp = false
    /// Set by `.release` (before uninstall): acts exactly like Pause but is never persisted, so a
    /// reinstall starts with the user's real settings. Cleared by `setPaused` and `.start`.
    var released = false
}

/// What the hardware should look like right now.
struct Actuation: Equatable {
    var chargeLimit: Int?
    var led: LEDState

    /// Stock macOS behaviour: used for Pause and release.
    static let released = Actuation(chargeLimit: nil, led: .system)
}

enum Policy {
    /// Pause, or released before uninstall.
    static func isPaused(_ settings: Settings, _ s: Session) -> Bool { settings.paused || s.released }

    /// Pause drops every running mode.
    static func clearForPause(_ s: inout Session) {
        s.toppingUp = false
    }

    /// Advances the session for a fresh snapshot: ends a Top Up on unplug.
    static func update(settings: Settings, snapshot: BatterySnapshot, session s: inout Session) {
        if isPaused(settings, s) {
            clearForPause(&s)
            return
        }
        if !snapshot.adapterConnected { s.toppingUp = false }
    }

    /// Derives the desired hardware state; no side effects.
    static func actuation(settings: Settings, snapshot: BatterySnapshot, session s: Session) -> Actuation {
        if isPaused(settings, s) { return .released }
        return Actuation(chargeLimit: requestedLimit(settings, paused: false, toppingUp: s.toppingUp),
                         led: led(settings.ledMode, snapshot))
    }

    /// The Charge Limit to ask for: none while paused, topping up or at 100. `Status.predicted` uses it too.
    static func requestedLimit(_ settings: Settings, paused: Bool, toppingUp: Bool) -> Int? {
        paused || toppingUp || settings.chargeLimit >= 100 ? nil : settings.chargeLimit
    }

    /// A Charge Limit below 80 didn't take: more is in effect than was asked for. `Status.predicted` uses it too.
    static func lowLimitUnsupported(effective: Int?, requested: Int?) -> Bool {
        guard let effective, let requested else { return false }
        return effective > requested
    }

    private static func led(_ mode: LEDMode, _ snapshot: BatterySnapshot) -> LEDState {
        if !snapshot.adapterConnected { return .system }
        if mode == .off { return .off }
        return snapshot.isCharging ? .orange : .green
    }
}

extension ChargeState {
    /// The Engine's state rule; `Status.predicted` uses it too, so a prediction can't drift from what energd reports.
    static func derive(paused: Bool, toppingUp: Bool, snapshot: BatterySnapshot?, effectiveLimit: Int?) -> ChargeState {
        if paused { return .paused }
        guard let snapshot else { return .unknown }
        if toppingUp { return .toppingUp }
        if !snapshot.adapterConnected { return .onBattery }
        if let limit = effectiveLimit, snapshot.percent > limit, !snapshot.isCharging { return .limitDrain }
        return snapshot.isCharging ? .charging : .atLimit
    }
}

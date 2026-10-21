/// Runtime state the Engine keeps between events (not persisted).
struct Session: Equatable {
    var toppingUp = false
    var weakSamples = 0
    var unavailable: Set<Feature> = []
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
        s.weakSamples = 0
    }

    /// Advances the session for a fresh snapshot: ends a Top Up on unplug and tracks Weak Adapter samples.
    /// `effectiveLimit`: above it the battery is in a Limit Drain, which is no Weak Adapter.
    /// `countsWeakSample`: only ticks count towards a Weak Adapter; other events can only reset the count.
    static func update(settings: Settings, snapshot: BatterySnapshot, effectiveLimit: Int?, countsWeakSample: Bool, session s: inout Session) {
        if isPaused(settings, s) {
            clearForPause(&s)
            return
        }
        if !snapshot.adapterConnected { s.toppingUp = false }
        // Charging is expected at or below the limit in effect; above it macOS drains to it on purpose.
        let chargingExpected = effectiveLimit.map { snapshot.percent <= $0 } ?? true
        let weak = snapshot.adapterConnected && chargingExpected && snapshot.batteryWatts < 0
        if !weak {
            s.weakSamples = 0
        } else if countsWeakSample {
            s.weakSamples += 1
        }
    }

    /// Derives the desired hardware state; no side effects.
    static func actuation(settings: Settings, snapshot: BatterySnapshot, session s: Session) -> Actuation {
        if isPaused(settings, s) { return .released }
        let limit: Int? = (s.toppingUp || settings.chargeLimit >= 100) ? nil : settings.chargeLimit
        return Actuation(chargeLimit: limit, led: led(settings.ledMode, snapshot))
    }

    private static func led(_ mode: LEDMode, _ snapshot: BatterySnapshot) -> LEDState {
        if !snapshot.adapterConnected { return .system }
        if mode == .off { return .off }
        return snapshot.isCharging ? .orange : .green
    }
}

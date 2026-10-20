import Foundation

/// User-chosen configuration; persisted by energd.
public struct Settings: Codable, Equatable, Sendable {
    /// Charge Limit values the native macOS limit accepts. 100 means "no limit".
    public static let allowedLimits = [80, 85, 90, 95, 100]

    public var chargeLimit: Int
    public var autoDischarge: Bool
    public var ledMode: LEDMode
    public var paused: Bool

    public init(chargeLimit: Int = 80, autoDischarge: Bool = true, ledMode: LEDMode = .auto, paused: Bool = false) {
        self.chargeLimit = chargeLimit
        self.autoDischarge = autoDischarge
        self.ledMode = ledMode
        self.paused = paused
    }
}

/// How EnerG drives the MagSafe LED.
public enum LEDMode: String, Codable, Sendable, CaseIterable {
    /// Orange while charging, green when holding, off during a Discharge.
    case auto
    /// Always off (while not paused and plugged in).
    case off
    /// Like auto, but slow blink during a Discharge.
    case blink
}

/// A concrete LED output. `system` hands the LED back to firmware.
public enum LEDState: String, Codable, Sendable {
    case system, off, green, orange, blinkSlow
}

/// One reading of battery and power state.
public struct BatterySnapshot: Codable, Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    /// A charger is physically plugged in (SMC `AC-W`). Stays true while EnerG cuts the adapter for a
    /// Discharge and while macOS reports "Battery Power" with the adapter on above the native limit.
    /// Falls back to IOKit `ExternalConnected` (adapter power reaches the Mac) if `AC-W` can't be read.
    public var adapterConnected: Bool
    /// Rated adapter wattage, if known.
    public var adapterWatts: Int?
    /// Positive while charging, negative while the battery supplies power.
    public var batteryWatts: Double
    /// Total system draw, if known.
    public var systemWatts: Double?

    public init(percent: Int, isCharging: Bool, adapterConnected: Bool,
                adapterWatts: Int?, batteryWatts: Double, systemWatts: Double?) {
        self.percent = percent
        self.isCharging = isCharging
        self.adapterConnected = adapterConnected
        self.adapterWatts = adapterWatts
        self.batteryWatts = batteryWatts
        self.systemWatts = systemWatts
    }
}

/// A hardware-backed capability that can become unavailable when its write fails.
public enum Feature: String, Codable, Sendable, CaseIterable {
    case chargeLimit, discharge, led
}

public enum ChargeState: String, Codable, Sendable {
    case charging, atLimit, discharging, toppingUp, paused, onBattery, unknown
}

public enum Warning: Codable, Hashable, Sendable {
    case weakAdapter
    case unavailable(Feature)
    case batteryUnreadable
}

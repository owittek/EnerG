import Foundation

/// User-chosen configuration; persisted by energd.
public struct Settings: Codable, Equatable, Sendable {
    /// Charge Limit values EnerG offers. 100 means "no limit"; below 80 goes through the smartcharging override (ADR 0001).
    public static let allowedLimits = Array(stride(from: 50, through: 100, by: 5))

    public var chargeLimit: Int
    public var ledMode: LEDMode
    public var paused: Bool

    public init(chargeLimit: Int = 80, ledMode: LEDMode = .auto, paused: Bool = false) {
        self.chargeLimit = chargeLimit
        self.ledMode = ledMode
        self.paused = paused
    }

    /// Each field falls back to its default when missing or invalid, so adding a field later keeps the others.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        chargeLimit = (try? c.decodeIfPresent(Int.self, forKey: .chargeLimit)) ?? d.chargeLimit
        ledMode = (try? c.decodeIfPresent(LEDMode.self, forKey: .ledMode)) ?? d.ledMode
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? d.paused
    }
}

/// How EnerG drives the MagSafe LED.
public enum LEDMode: String, Codable, Sendable, CaseIterable {
    /// Orange while charging, green otherwise while plugged in.
    case auto
    /// Always off (while not paused and plugged in).
    case off
}

/// A concrete LED output. `system` hands the LED back to firmware.
public enum LEDState: String, Codable, Sendable {
    case system, off, green, orange
}

/// One reading of battery and power state.
public struct BatterySnapshot: Codable, Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    /// A charger is physically plugged in (SMC `AC-W`). Stays true while EnerG pulses the adapter and while
    /// macOS reports "Battery Power" with the adapter on above the native limit.
    /// Falls back to IOKit `ExternalConnected` (adapter power reaches the Mac) if `AC-W` can't be read.
    public var adapterConnected: Bool
    /// Rated adapter wattage, if known.
    public var adapterWatts: Int?
    /// Positive while charging, negative while the battery supplies power.
    public var batteryWatts: Double
    /// Total system draw, if known.
    public var systemWatts: Double?
    /// `adapterConnected` was read from `AC-W`, so it stays true while `CHIE` cuts the adapter.
    /// False on the `ExternalConnected` fallback, where a cut itself reads as unplugged.
    public var plugSensed: Bool

    public init(percent: Int, isCharging: Bool, adapterConnected: Bool,
                adapterWatts: Int?, batteryWatts: Double, systemWatts: Double?, plugSensed: Bool = true) {
        self.percent = percent
        self.isCharging = isCharging
        self.adapterConnected = adapterConnected
        self.adapterWatts = adapterWatts
        self.batteryWatts = batteryWatts
        self.systemWatts = systemWatts
        self.plugSensed = plugSensed
    }

    /// `plugSensed` defaults to true when missing, so an app can read an older energd's Status.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        percent = try c.decode(Int.self, forKey: .percent)
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        adapterConnected = try c.decode(Bool.self, forKey: .adapterConnected)
        adapterWatts = try c.decodeIfPresent(Int.self, forKey: .adapterWatts)
        batteryWatts = try c.decode(Double.self, forKey: .batteryWatts)
        systemWatts = try c.decodeIfPresent(Double.self, forKey: .systemWatts)
        plugSensed = try c.decodeIfPresent(Bool.self, forKey: .plugSensed) ?? true
    }
}

/// A hardware-backed capability that can become unavailable when its write fails.
public enum Feature: String, Codable, Sendable, CaseIterable {
    case chargeLimit, led
}

public enum ChargeState: String, Codable, Sendable {
    case charging, atLimit, limitDrain, toppingUp, paused, onBattery, unknown
}

public enum Warning: Codable, Hashable, Sendable {
    /// A Charge Limit below 80 didn't take, so 80 is in effect.
    case lowLimitUnsupported
    case unavailable(Feature)
    case batteryUnreadable
}

import Foundation

/// Names shared by EnerG.app, energd and the launchd plist.
public enum DaemonID {
    public static let machService = "app.energ.energd"
    public static let plistName = "app.energ.energd.plist"
}

/// A message from EnerG.app to energd. Every request is answered with a `Status`.
public enum Request: Codable, Equatable, Sendable {
    case getStatus
    case setLimit(Int)
    case topUp
    /// Ends a Top Up early; the Charge Limit applies again.
    case cancelTopUp
    case setLEDMode(LEDMode)
    case setPaused(Bool)
    /// Hand everything back to macOS like Pause, without persisting it; sent before uninstalling
    /// the helper, so a reinstall starts with the user's real settings. `setPaused` or a restart ends it.
    case release
}

public struct Status: Codable, Equatable, Sendable {
    public var state: ChargeState
    public var settings: Settings
    /// nil when the battery could not be read.
    public var snapshot: BatterySnapshot?
    /// The native Charge Limit in effect: the setting, or 80 when a lower one didn't take. nil while off,
    /// paused, topping up, or when the Charge Limit is unavailable.
    public var effectiveLimit: Int?
    /// A Top Up is active. Also true while `state` shows something else, e.g. `.unknown`.
    public var toppingUp: Bool
    public var warnings: [Warning]

    public init(state: ChargeState, settings: Settings, snapshot: BatterySnapshot?,
                effectiveLimit: Int?, toppingUp: Bool, warnings: [Warning]) {
        self.state = state
        self.settings = settings
        self.snapshot = snapshot
        self.effectiveLimit = effectiveLimit
        self.toppingUp = toppingUp
        self.warnings = warnings
    }
}

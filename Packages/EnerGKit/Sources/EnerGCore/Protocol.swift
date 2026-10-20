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
    case discharge(to: Int)
    case cancelDischarge
    case topUp
    /// Ends a Top Up early; the Charge Limit applies again.
    case cancelTopUp
    case setLEDMode(LEDMode)
    case setAutoDischarge(Bool)
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
    /// Set while a Discharge is running.
    public var dischargeTarget: Int?
    /// A Top Up is active. Also true while `state` shows something else, e.g. `.unknown`.
    public var toppingUp: Bool
    public var warnings: [Warning]

    public init(state: ChargeState, settings: Settings, snapshot: BatterySnapshot?,
                dischargeTarget: Int?, toppingUp: Bool, warnings: [Warning]) {
        self.state = state
        self.settings = settings
        self.snapshot = snapshot
        self.dischargeTarget = dischargeTarget
        self.toppingUp = toppingUp
        self.warnings = warnings
    }
}

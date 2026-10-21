/// Everything the Engine needs from the machine. Writes may throw; the Engine
/// then marks the matching `Feature` unavailable and stops writing it.
public protocol Hardware: AnyObject {
    func snapshot() throws -> BatterySnapshot
    /// Sets the native Charge Limit; nil disables it.
    func setChargeLimit(_ percent: Int?) throws
    func setLED(_ state: LEDState) throws
}

public enum HardwareError: Error, Equatable, Sendable {
    case notPrivileged
    case keyMissing(String)
    case frameworkUnavailable
    case io(Int32)
}

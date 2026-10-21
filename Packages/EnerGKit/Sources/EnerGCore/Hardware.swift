/// Everything the Engine needs from the machine. Writes may throw; the Engine
/// then marks the matching `Feature` unavailable and stops writing it.
public protocol Hardware: AnyObject {
    func snapshot() throws -> BatterySnapshot
    /// Sets the native Charge Limit; nil disables it. Returns the limit now in effect: `percent`, or 80 when
    /// this Mac doesn't accept a value below 80; nil when disabled.
    func setChargeLimit(_ percent: Int?) throws -> Int?
    func setLED(_ state: LEDState) throws
}

public enum HardwareError: Error, Equatable, Sendable {
    case notPrivileged
    case keyMissing(String)
    case frameworkUnavailable
    case io(Int32)
}

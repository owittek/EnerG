/// Everything the Engine needs from the machine. Writes may throw; the Engine
/// then marks the matching `Feature` unavailable and stops writing it (`HardwareError.adapterCut` is retried once).
public protocol Hardware: AnyObject {
    func snapshot() throws -> BatterySnapshot
    /// Sets the native Charge Limit; nil disables it. Returns the limit now in effect: `percent`, or 80 when
    /// this Mac doesn't accept a value below 80; nil when disabled.
    /// Throws `HardwareError.adapterCut` when a pulse left the adapter cut.
    func setChargeLimit(_ percent: Int?) throws -> Int?
    func setLED(_ state: LEDState) throws
}

public enum HardwareError: Error, Equatable, Sendable {
    case notPrivileged
    case keyMissing(String)
    case frameworkUnavailable
    case io(Int32)
    /// A pulse left the adapter cut: every re-enable failed. The next snapshot turns it back on.
    case adapterCut
}

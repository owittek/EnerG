/// Everything the Engine needs from the machine. Writes may throw; the Engine
/// then marks the matching `Feature` unavailable and stops writing it (`HardwareError.adapterCut` is retried once).
public protocol Hardware: AnyObject {
    /// Reads the battery. An adapter may also turn a cut adapter back on here, so call it after a write that threw
    /// `HardwareError.adapterCut`.
    func snapshot() throws -> BatterySnapshot
    /// Sets the native Charge Limit; nil disables it. Whether a limit took is judged later from snapshots
    /// (`BatterySnapshot.firmwareLimit`). Throws `HardwareError.adapterCut` when a pulse left the adapter cut.
    func setChargeLimit(_ percent: Int?) throws
    func setLED(_ state: LEDState) throws
    /// The LED state the hardware holds now; nil when unreadable. macOS can change it on its own, e.g. a few seconds
    /// after an unplug. Reads `.green` or `.orange` while the system drives it, so only `.off`, `.green` and `.orange`
    /// can be told apart.
    func readLED() -> LEDState?
}

public enum HardwareError: Error, Equatable, Sendable {
    case notPrivileged
    case keyMissing(String)
    case frameworkUnavailable
    case io(Int32)
    /// A pulse left the adapter cut: every re-enable failed. The next snapshot turns it back on.
    case adapterCut
}

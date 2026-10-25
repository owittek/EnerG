import Foundation
import IOKit
import CPlatform
import EnerGCore
import OSLog
import notify

/// The real Mac: AppleSMC (CHIE adapter pulse, ACLC LED, PSTR system power, AC-W plug presence, B0AC/B0AV battery power), PowerUI native
/// Charge Limit, and the AppleSmartBattery registry entry. Writes need root.
/// The native Charge Limit goes through `NativeLimit`, with this class as its `LimitControls`.
/// SMC reads straight after a write can return the old value; the Engine never reads back, so this is harmless.
public final class MacHardware: Hardware, LimitControls {
    private let smc: io_connect_t
    private let log = Logger(subsystem: "app.energ", category: "hardware")
    /// Holds `self` as its controls; MacHardware lives for the whole process, so the cycle is harmless.
    private lazy var nativeLimit = NativeLimit(controls: self)
    /// `snapshot()` turns a cut adapter back on. energ-smoke passes false so its `adapter off` sticks.
    private let healsAdapter: Bool

    public init(healsAdapter: Bool = true) throws {
        var conn: io_connect_t = 0
        let kr = smc_open(&conn)
        guard kr == KERN_SUCCESS else { throw HardwareError.io(kr) }
        smc = conn
        self.healsAdapter = healsAdapter
    }

    deinit {
        smc_close(smc)
    }

    public func snapshot() throws -> BatterySnapshot {
        if healsAdapter { healAdapter() }
        let p = try Self.batteryProperties()
        func number(_ key: String) -> NSNumber? { p[key] as? NSNumber }
        guard let percent = number("CurrentCapacity")?.intValue else { throw HardwareError.keyMissing("CurrentCapacity") }
        let milliamps = Double(number("InstantAmperage")?.int64Value ?? 0)
        let millivolts = Double(number("Voltage")?.int64Value ?? 0)
        let adapter = p["AdapterDetails"] as? [String: Any]
        let plugged = physicallyPlugged()
        let adapterConnected = plugged ?? (p["ExternalConnected"] as? Bool ?? false)
        let chlt = try? read("CHLT", size: 3)
        return BatterySnapshot(
            percent: percent,
            isCharging: BatterySnapshot.isCharging(chlt: chlt, percent: percent,
                                                   adapterConnected: adapterConnected,
                                                   registryIsCharging: p["IsCharging"] as? Bool ?? false),
            adapterConnected: adapterConnected,
            adapterWatts: (adapter?["Watts"] as? NSNumber)?.intValue,
            batteryWatts: liveBatteryWatts() ?? milliamps * millivolts / 1_000_000,
            systemWatts: (try? readFloat("PSTR")).map(Double.init),
            plugSensed: plugged != nil,
            firmwareLimit: chlt.flatMap { $0[0] == 0 ? nil : Int($0[0]) }
        )
    }

    public func setChargeLimit(_ percent: Int?) throws {
        try nativeLimit.set(percent)
    }

    /// PowerUI's native Charge Limit and whether it is on, as System Settings shows it (energ-smoke).
    public func nativeLimitState() throws -> (limit: Int, enabled: Bool) {
        var limit: UInt8 = 0
        var enabled = false
        try check(powerui_get_limit(&limit, &enabled))
        return (Int(limit), enabled)
    }

    /// `NativeLimit.healAdapter`, logging a failed re-enable. The Engine takes a snapshot on every event (`.start`
    /// and `.stop` included), from the same serial context as `setChargeLimit`, so this never runs mid-pulse.
    /// Never throws.
    private func healAdapter() {
        do { try nativeLimit.healAdapter() } catch {
            log.error("adapter re-enable failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - LimitControls

    public func setMCL(_ percent: Int?) throws {
        if let percent {
            // enableMCL: resets the limit to 80; setMCLLimit: also enables. Accepts 80...100 only.
            try check(powerui_set_limit(UInt8(percent)))
        } else {
            try check(powerui_set_enabled(false))
        }
    }

    /// A String, not a CFString: a static CF value isn't concurrency-safe under Swift 6.
    private static let smartChargingDomain = "com.apple.smartcharging.topoffprotection"

    public func writeOverride(_ percent: Int) throws {
        // energd runs as root, so this is root's domain, the one the smartcharging daemon reads.
        let domain = Self.smartChargingDomain as CFString
        CFPreferencesSetValue("mclLimitValue" as CFString, NSNumber(value: percent), domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            log.error("writing the smartcharging override failed")
            throw HardwareError.io(-3)
        }
    }

    public func notifyDefaultsChanged() {
        notify_post("com.apple.smartcharging.defaultschanged")
    }

    /// `CHLT` = `[limit, band, status]`; byte 0 is the limit the firmware enforces, 0 when off.
    public func smcLimit() -> Int? {
        guard let bytes = try? read("CHLT", size: 3), bytes[0] != 0 else { return nil }
        return Int(bytes[0])
    }

    /// Unknown counts as plugged in: a pulse with nothing plugged in is harmless.
    public func pluggedIn() -> Bool { physicallyPlugged() ?? true }

    public func adapterReadsCut() -> Bool {
        guard let chie = try? read("CHIE", size: 1) else { return false }
        return chie[0] != 0x00
    }

    public func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    public func setAdapter(enabled: Bool) throws {
        try write("CHIE", enabled ? 0x00 : 0x08)
    }

    public func setLED(_ state: LEDState) throws {
        let value: UInt8 = switch state {
        case .system: 0x00
        case .off: 0x01
        case .green: 0x03
        case .orange: 0x04
        }
        try write("ACLC", value)
    }

    public func readLED() -> LEDState? {
        switch try? read("ACLC", size: 1).first {
        case 0x00: .system
        case 0x01: .off
        case 0x03: .green
        case 0x04: .orange
        default: nil
        }
    }

    // MARK: - SMC

    private static let notPrivileged = kern_return_t(bitPattern: 0xE000_02C1)
    private static let keyNotFound: UInt8 = 132

    private func write(_ key: String, _ byte: UInt8) throws {
        var result: UInt8 = 0
        var value = byte
        let kr = smc_write(smc, key, &value, 1, &result)
        try checkSMC(kr, result, key)
    }

    /// `AC-W` (si8): > 0 while a charger is physically plugged in, also while CHIE cuts it
    /// (ExternalConnected then reads No); -1 when unplugged. nil if the key is missing or unreadable.
    private func physicallyPlugged() -> Bool? {
        guard let bytes = try? read("AC-W", size: 1) else { return nil }
        return Int8(bitPattern: bytes[0]) > 0
    }

    /// Battery power from `B0AC` (si16 mA, negative while supplying power) × `B0AV` (ui16 mV). Live, unlike the
    /// registry, which refreshes about once a minute. nil if either key can't be read.
    private func liveBatteryWatts() -> Double? {
        guard let current = try? read("B0AC", size: 2), let voltage = try? read("B0AV", size: 2) else { return nil }
        let milliamps = Int16(bitPattern: UInt16(current[0]) | UInt16(current[1]) << 8)
        let millivolts = UInt16(voltage[0]) | UInt16(voltage[1]) << 8
        return Double(milliamps) * Double(millivolts) / 1_000_000
    }

    private func readFloat(_ key: String) throws -> Float {
        let b = try read(key, size: 4)
        return Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }

    /// Reads a key that must be exactly `size` bytes (little-endian on Apple Silicon).
    private func read(_ key: String, size expected: UInt32) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var result: UInt8 = 0
        let kr = smc_read(smc, key, &buf, &size, &result)
        try checkSMC(kr, result, key)
        guard size == expected else { throw HardwareError.keyMissing(key) }
        return Array(buf.prefix(Int(size)))
    }

    private func checkSMC(_ kr: kern_return_t, _ result: UInt8, _ key: String) throws {
        if kr == Self.notPrivileged { throw HardwareError.notPrivileged }
        guard kr == KERN_SUCCESS else { throw HardwareError.io(kr) }
        if result == Self.keyNotFound { throw HardwareError.keyMissing(key) }
        guard result == 0 else { throw HardwareError.io(Int32(result)) }
    }

    private func check(_ rc: Int32) throws {
        switch rc {
        case 0: return
        case -1: throw HardwareError.frameworkUnavailable
        default: throw HardwareError.io(rc)
        }
    }

    // MARK: - Battery registry

    private static func batteryProperties() throws -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { throw HardwareError.keyMissing("AppleSmartBattery") }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] else {
            throw HardwareError.io(kr)
        }
        return dict
    }
}

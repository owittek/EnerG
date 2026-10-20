import Foundation
import IOKit
import IOKit.pwr_mgt
import CPlatform
import EnerGCore

/// The real Mac: AppleSMC (CHIE adapter cut, ACLC LED, PSTR system power, AC-W plug presence), PowerUI native
/// Charge Limit, and the AppleSmartBattery registry entry. Writes need root.
/// SMC reads straight after a write can return the old value; the Engine never reads back, so this is harmless.
public final class MacHardware: Hardware {
    private let smc: io_connect_t
    private var sleepAssertion: IOPMAssertionID = 0

    public init() throws {
        var conn: io_connect_t = 0
        let kr = smc_open(&conn)
        guard kr == KERN_SUCCESS else { throw HardwareError.io(kr) }
        smc = conn
    }

    deinit {
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
        smc_close(smc)
    }

    public func snapshot() throws -> BatterySnapshot {
        let p = try Self.batteryProperties()
        func number(_ key: String) -> NSNumber? { p[key] as? NSNumber }
        guard let percent = number("CurrentCapacity")?.intValue else { throw HardwareError.keyMissing("CurrentCapacity") }
        let milliamps = Double(number("InstantAmperage")?.int64Value ?? 0)
        let millivolts = Double(number("Voltage")?.int64Value ?? 0)
        let adapter = p["AdapterDetails"] as? [String: Any]
        return BatterySnapshot(
            percent: percent,
            isCharging: p["IsCharging"] as? Bool ?? false,
            adapterConnected: physicallyPlugged() ?? (p["ExternalConnected"] as? Bool ?? false),
            adapterWatts: (adapter?["Watts"] as? NSNumber)?.intValue,
            batteryWatts: milliamps * millivolts / 1_000_000,
            systemWatts: (try? readFloat("PSTR")).map(Double.init)
        )
    }

    public func setChargeLimit(_ percent: Int?) throws {
        if let percent {
            // enableMCL: resets the limit to 80; setMCLLimit: also enables
            try check(powerui_set_limit(UInt8(percent)))
        } else {
            try check(powerui_set_enabled(false))
        }
    }

    public func setAdapter(enabled: Bool) throws {
        try write("CHIE", enabled ? 0x00 : 0x08)
    }

    public func setLED(_ state: LEDState) throws {
        let value: UInt8 = switch state {
        case .system: 0x00
        case .off: 0x01
        case .green: 0x03
        case .orange: 0x04
        case .blinkSlow: 0x06
        }
        try write("ACLC", value)
    }

    public func setPreventSleep(_ on: Bool) {
        if on, sleepAssertion == 0 {
            IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "EnerG Discharge" as CFString, &sleepAssertion)
        } else if !on, sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
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
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var result: UInt8 = 0
        let kr = smc_read(smc, "AC-W", &buf, &size, &result)
        guard (try? checkSMC(kr, result, "AC-W")) != nil, size == 1 else { return nil }
        return Int8(bitPattern: buf[0]) > 0
    }

    private func readFloat(_ key: String) throws -> Float {
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var result: UInt8 = 0
        let kr = smc_read(smc, key, &buf, &size, &result)
        try checkSMC(kr, result, key)
        guard size == 4 else { throw HardwareError.keyMissing(key) }
        let bits = UInt32(buf[0]) | UInt32(buf[1]) << 8 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 24
        return Float(bitPattern: bits)
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

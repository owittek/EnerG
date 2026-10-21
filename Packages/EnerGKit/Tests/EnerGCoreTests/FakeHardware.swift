@testable import EnerGCore

/// Records writes; tests set `snap` to simulate the battery.
final class FakeHardware: Hardware {
    enum Write: Equatable {
        case limit(Int?), led(LEDState)
    }

    var snap = BatterySnapshot(percent: 70, isCharging: true, adapterConnected: true,
                               adapterWatts: 96, batteryWatts: 20, systemWatts: 15)
    var writes: [Write] = []
    var failing: Set<Feature> = []
    /// Non-nil limits whose write throws; disabling the limit still succeeds.
    var failingLimits: Set<Int> = []
    /// Non-nil limit writes that throw `adapterCut` before one succeeds.
    var adapterCuts = 0
    var snapshotFails = false
    /// false: limits below 80 don't take and 80 is in effect instead, like a macOS that clamps the override (once plugged in).
    var acceptsBelow80 = true

    func snapshot() throws -> BatterySnapshot {
        if snapshotFails { throw HardwareError.io(-1) }
        return snap
    }

    func setChargeLimit(_ percent: Int?) throws -> Int? {
        if failing.contains(.chargeLimit) { throw HardwareError.notPrivileged }
        if let percent, failingLimits.contains(percent) { throw HardwareError.io(-2) }
        if percent != nil, adapterCuts > 0 {
            adapterCuts -= 1
            throw HardwareError.adapterCut
        }
        writes.append(.limit(percent))
        // Unplugged, the real NativeLimit returns a value below 80 unverified: only the plug-in applies it.
        if let percent, percent < 80, !acceptsBelow80, snap.adapterConnected { return 80 }
        return percent
    }

    func setLED(_ state: LEDState) throws {
        if failing.contains(.led) { throw HardwareError.notPrivileged }
        writes.append(.led(state))
    }
}

/// An Engine that has handled `.start`, with the start writes cleared.
func started(_ settings: Settings = Settings(),
             _ configure: (FakeHardware) -> Void = { _ in }) -> (Engine, FakeHardware) {
    let hw = FakeHardware()
    configure(hw)
    let engine = Engine(hardware: hw, settings: settings)
    engine.handle(.start)
    hw.writes.removeAll()
    return (engine, hw)
}

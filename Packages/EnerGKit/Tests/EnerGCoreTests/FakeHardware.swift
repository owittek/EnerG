@testable import EnerGCore

/// Records writes; tests set `snap` to simulate the battery.
final class FakeHardware: Hardware {
    enum Write: Equatable {
        case limit(Int?), adapter(Bool), led(LEDState), preventSleep(Bool)
    }

    var snap = BatterySnapshot(percent: 70, isCharging: true, adapterConnected: true,
                               adapterWatts: 96, batteryWatts: 20, systemWatts: 15)
    var writes: [Write] = []
    var failing: Set<Feature> = []
    var snapshotFails = false

    func snapshot() throws -> BatterySnapshot {
        if snapshotFails { throw HardwareError.io(-1) }
        return snap
    }

    func setChargeLimit(_ percent: Int?) throws {
        if failing.contains(.chargeLimit) { throw HardwareError.notPrivileged }
        writes.append(.limit(percent))
    }

    func setAdapter(enabled: Bool) throws {
        if failing.contains(.discharge) { throw HardwareError.notPrivileged }
        writes.append(.adapter(enabled))
    }

    func setLED(_ state: LEDState) throws {
        if failing.contains(.led) { throw HardwareError.notPrivileged }
        writes.append(.led(state))
    }

    func setPreventSleep(_ on: Bool) {
        writes.append(.preventSleep(on))
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

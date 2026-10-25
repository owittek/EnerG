import Foundation
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
    var snapshotCalls = 0
    /// false: limits below 80 read as 80 in `CHLT`, like a macOS that clamps the override.
    var acceptsBelow80 = true
    /// What `CHLT[0]` holds; limit writes land here, clamped to 80 without `acceptsBelow80`.
    var chlt: Int? = 80
    /// macOS ignores every limit (Calibration): snapshots read `CHLT` off.
    var calibrating = false
    /// The Engine's clock (see `started`).
    var now = Date(timeIntervalSince1970: 0)
    /// What `readLED` returns: the last LED written; tests set it to simulate macOS changing the LED.
    var led: LEDState?

    func advance(_ seconds: TimeInterval) { now += seconds }

    func snapshot() throws -> BatterySnapshot {
        snapshotCalls += 1
        if snapshotFails { throw HardwareError.io(-1) }
        var s = snap
        s.firmwareLimit = calibrating ? nil : chlt
        return s
    }

    func setChargeLimit(_ percent: Int?) throws {
        if failing.contains(.chargeLimit) { throw HardwareError.notPrivileged }
        if let percent, failingLimits.contains(percent) { throw HardwareError.io(-2) }
        if percent != nil, adapterCuts > 0 {
            adapterCuts -= 1
            throw HardwareError.adapterCut
        }
        writes.append(.limit(percent))
        chlt = percent.map { acceptsBelow80 ? $0 : max($0, 80) }
    }

    func setLED(_ state: LEDState) throws {
        if failing.contains(.led) { throw HardwareError.notPrivileged }
        writes.append(.led(state))
        led = state
    }

    func readLED() -> LEDState? { led }
}

/// An Engine that has handled `.start`, with the start writes cleared.
func started(_ settings: Settings = Settings(),
             _ configure: (FakeHardware) -> Void = { _ in }) -> (Engine, FakeHardware) {
    let hw = FakeHardware()
    configure(hw)
    let engine = Engine(hardware: hw, settings: settings, now: { hw.now })
    engine.handle(.start)
    hw.writes.removeAll()
    return (engine, hw)
}

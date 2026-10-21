import Foundation
@testable import EnerGCore

/// Scripts how the smartcharging daemon reacts to an override; records every write.
final class FakeLimitControls: LimitControls {
    enum Call: Equatable {
        case setMCL(Int?), override(Int), notify, adapter(Bool)
    }
    enum Daemon {
        /// Pushes the override to the SMC on the notification (the % happened to change).
        case appliesOnNotify
        /// Pushes it only on a plug event, i.e. the CHIE pulse (the % is steady).
        case appliesOnPulse
        /// Never pushes it (a macOS that clamps the override).
        case neverApplies
    }

    var daemon = Daemon.appliesOnNotify
    var calls: [Call] = []
    /// What `CHLT[0]` reads; PowerUI writes land here at once.
    var chlt: Int? = 80
    var plugged = true
    var failingMCL = false
    var failingOverride = false
    /// Adapter-on writes that throw before one succeeds.
    var failingEnables = 0
    /// Adapter-off writes throw.
    var failingCut = false
    private var pending: Int?

    func setMCL(_ percent: Int?) throws {
        if failingMCL { throw HardwareError.io(-2) }
        calls.append(.setMCL(percent))
        chlt = percent
        pending = nil
    }

    func writeOverride(_ percent: Int) throws {
        if failingOverride { throw HardwareError.io(-3) }
        calls.append(.override(percent))
        pending = percent
    }

    func notifyDefaultsChanged() {
        calls.append(.notify)
        if daemon == .appliesOnNotify, let pending { chlt = pending }
    }

    func smcLimit() -> Int? { chlt }

    func pluggedIn() -> Bool { plugged }

    func setAdapter(enabled: Bool) throws {
        if !enabled, failingCut { throw HardwareError.io(-1) }
        if enabled, failingEnables > 0 {
            failingEnables -= 1
            throw HardwareError.io(-1)
        }
        calls.append(.adapter(enabled))
        if enabled, daemon == .appliesOnPulse, let pending { chlt = pending }
    }

    func wait(_ seconds: TimeInterval) {}
}

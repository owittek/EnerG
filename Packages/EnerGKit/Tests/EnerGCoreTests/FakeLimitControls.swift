import Foundation
@testable import EnerGCore

/// Scripts how the smartcharging daemon reacts to an override; records every write.
final class FakeLimitControls: LimitControls {
    enum Call: Equatable {
        case setMCL(Int?), override(Int), notify, adapter(Bool)
    }
    enum Daemon: Equatable {
        /// Pushes the override to the SMC on the notification (the % happened to change).
        case appliesOnNotify
        /// Pushes it only on a plug event, i.e. the CHIE pulse (the % is steady).
        case appliesOnPulse
        /// Pushes it after this many `wait` calls (the daemon takes a moment).
        case appliesAfterWaits(Int)
        /// Never pushes it (a macOS that clamps the override).
        case neverApplies
    }

    var daemon = Daemon.appliesOnNotify
    var calls: [Call] = []
    /// Every `wait`, in seconds; kept out of `calls` so call sequences stay readable.
    var waits: [TimeInterval] = []
    /// What `CHLT[0]` holds; PowerUI writes land here at once.
    var chlt: Int? = 80
    /// A `CHLT` read after a change returns the value from before it, until the next `wait`.
    var staleReads = false
    var plugged = true
    var failingMCL = false
    var failingOverride = false
    /// Adapter-on writes that throw before one succeeds.
    var failingEnables = 0
    /// Adapter-off writes throw.
    var failingCut = false
    private var pending: Int?
    private var waitsLeft = 0
    private var isStale = false
    private var staleValue: Int?

    func setMCL(_ percent: Int?) throws {
        if failingMCL { throw HardwareError.io(-2) }
        calls.append(.setMCL(percent))
        setCHLT(percent)
        pending = nil
    }

    func writeOverride(_ percent: Int) throws {
        if failingOverride { throw HardwareError.io(-3) }
        calls.append(.override(percent))
        pending = percent
        if case .appliesAfterWaits(let n) = daemon { waitsLeft = n }
    }

    func notifyDefaultsChanged() {
        calls.append(.notify)
        if daemon == .appliesOnNotify, let pending { setCHLT(pending) }
    }

    func smcLimit() -> Int? { isStale ? staleValue : chlt }

    func pluggedIn() -> Bool { plugged }

    func setAdapter(enabled: Bool) throws {
        if !enabled, failingCut { throw HardwareError.io(-1) }
        if enabled, failingEnables > 0 {
            failingEnables -= 1
            throw HardwareError.io(-1)
        }
        calls.append(.adapter(enabled))
        if enabled, daemon == .appliesOnPulse, let pending { setCHLT(pending) }
    }

    func wait(_ seconds: TimeInterval) {
        waits.append(seconds)
        isStale = false
        guard case .appliesAfterWaits = daemon, let pending else { return }
        waitsLeft -= 1
        if waitsLeft == 0 { setCHLT(pending) }
    }

    /// Moves `CHLT`; with `staleReads`, reads keep the old value until the next `wait`.
    private func setCHLT(_ value: Int?) {
        if staleReads, !isStale {
            staleValue = chlt
            isStale = true
        }
        chlt = value
    }
}

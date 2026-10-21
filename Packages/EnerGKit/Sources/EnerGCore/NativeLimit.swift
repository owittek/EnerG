import Foundation

/// The machine primitives behind the native Charge Limit. `MacHardware` implements them; writes need root.
public protocol LimitControls: AnyObject {
    /// PowerUI: sets and enables the native limit (it accepts 80...100 only); nil disables it.
    func setMCL(_ percent: Int?) throws
    /// Writes `mclLimitValue` into root's `com.apple.smartcharging.topoffprotection` defaults.
    func writeOverride(_ percent: Int) throws
    /// Posts `com.apple.smartcharging.defaultschanged` so the smartcharging daemon re-reads its defaults.
    func notifyDefaultsChanged()
    /// The limit the firmware enforces (`CHLT` byte 0); nil when off or unreadable.
    func smcLimit() -> Int?
    /// A charger is physically plugged in.
    func pluggedIn() -> Bool
    /// SMC `CHIE`: false cuts adapter power.
    func setAdapter(enabled: Bool) throws
    func wait(_ seconds: TimeInterval)
}

/// Sets the native Charge Limit, including values below 80 that PowerUI rejects (ADR 0001). Those go through
/// the smartcharging defaults override. The daemon applies an override on its next % change or plug event,
/// so when the battery is steady a `CHIE` pulse supplies the plug event.
public final class NativeLimit {
    /// PowerUI's lowest accepted limit, and the fallback when a lower one doesn't take.
    public static let powerUIMinimum = 80
    private static let pollInterval: TimeInterval = 0.25

    private let controls: any LimitControls
    /// How long to wait, per attempt, for the daemon to push an override to the SMC.
    private let settle: TimeInterval
    /// `CHIE` was found cut: the next `set` disables the limit first, so macOS doesn't stay on battery.
    private var adapterCut = false

    public init(controls: any LimitControls, settle: TimeInterval = 2) {
        self.controls = controls
        self.settle = settle
    }

    /// Call when the adapter was found cut and has been turned back on, never while a `set` is running.
    public func adapterWasCut() { adapterCut = true }

    /// Sets the limit; nil disables it. Returns the limit now in effect: `percent`, or `powerUIMinimum` when a
    /// lower value didn't take. Below `powerUIMinimum` while unplugged, `percent` is returned unverified, because the
    /// plug-in applies it; the Engine sets it again on plug-in to check. Throws when PowerUI fails, or
    /// `HardwareError.adapterCut` when the adapter can't be turned back on after a pulse.
    /// Can block for about 5 s when a pulse is needed.
    public func set(_ percent: Int?) throws -> Int? {
        let reapplying = adapterCut
        // Read before the re-apply disable, which turns the limit off.
        let current = controls.smcLimit()
        if reapplying {
            try controls.setMCL(nil)
            adapterCut = false
        }
        guard let percent else {
            // Leave Apple's domain holding a value System Settings can show.
            if let current, current < Self.powerUIMinimum { try controls.setMCL(Self.powerUIMinimum) }
            try controls.setMCL(nil)
            return nil
        }
        if percent >= Self.powerUIMinimum {
            try controls.setMCL(percent)
            return percent
        }
        // A CHLT read straight after a write can return the old value, so after a re-apply it isn't trusted.
        if !reapplying, current == percent { return percent }
        if reapplying || current == nil { try controls.setMCL(Self.powerUIMinimum) }
        do {
            try controls.writeOverride(percent)
        } catch {
            return try fallBack()
        }
        controls.notifyDefaultsChanged()
        if waitUntilApplied(percent, afterReapply: reapplying) { return percent }
        guard controls.pluggedIn() else { return percent }
        // A failed cut leaves the override in place but nothing to apply it now.
        guard try pulse() else { return try fallBack() }
        if waitUntilApplied(percent, afterReapply: false) { return percent }
        return try fallBack()
    }

    private func fallBack() throws -> Int {
        try controls.setMCL(Self.powerUIMinimum)
        return Self.powerUIMinimum
    }

    /// `afterReapply`: the disable and `setMCL(80)` just went out, so the first read waits one poll, as it could be stale.
    private func waitUntilApplied(_ percent: Int, afterReapply: Bool) -> Bool {
        var waited: TimeInterval = 0
        if afterReapply {
            controls.wait(Self.pollInterval)
            waited += Self.pollInterval
        }
        while controls.smcLimit() != percent {
            if waited >= settle { return false }
            controls.wait(Self.pollInterval)
            waited += Self.pollInterval
        }
        return true
    }

    /// A cut and reconnect reads as a plug event to the smartcharging daemon. Returns false when the cut fails
    /// (the adapter was never cut); throws `HardwareError.adapterCut` when the adapter can't be turned back on.
    private func pulse() throws -> Bool {
        do { try controls.setAdapter(enabled: false) } catch { return false }
        controls.wait(1)
        // Turning the adapter back on is the safe direction: retry before giving up.
        for _ in 1..<3 {
            do {
                try controls.setAdapter(enabled: true)
                return true
            } catch {
                controls.wait(0.5)
            }
        }
        do {
            try controls.setAdapter(enabled: true)
        } catch {
            // The snapshot's heal turns it back on; the next set must then re-apply.
            adapterCut = true
            throw HardwareError.adapterCut
        }
        return true
    }
}

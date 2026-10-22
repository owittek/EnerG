/// Writes an `Actuation` through `Hardware`, only the fields that changed, and keeps what the writes reported: the
/// Charge Limit in effect and the Features whose writes failed. Not thread-safe: call from the Engine's serial context.
final class Actuator {
    private let hardware: any Hardware
    /// Last actuation written; nil means unknown, so everything is written.
    private var applied: Actuation?
    /// What `setChargeLimit` reported in effect; nil when off, unavailable or not written yet.
    private(set) var effectiveLimit: Int?
    /// Features whose write failed; not written again until `reset`.
    private(set) var unavailable: Set<Feature> = []
    /// The last Charge Limit write left the adapter cut; a second one in a row makes it unavailable.
    private var adapterLeftCut = false
    /// A write is to be retried: the next `apply` re-asserts everything.
    private var retryNextApply = false
    /// The Charge Limit last asked for; kept apart from `applied`, which a retry clears, so the warning holds.
    private var requestedLimit: Int?
    /// The last Charge Limit write was below 80 and made while unplugged, so it was returned unverified.
    private var limitUnverified = false

    init(hardware: any Hardware) {
        self.hardware = hardware
    }

    /// A Charge Limit below 80 didn't take, so 80 is in effect.
    var lowLimitUnsupported: Bool {
        Policy.lowLimitUnsupported(effective: effectiveLimit, requested: requestedLimit)
    }

    /// Daemon launch: hardware state is unknown and every Feature is tried again.
    func reset() {
        applied = nil
        effectiveLimit = nil
        unavailable = []
        adapterLeftCut = false
    }

    /// Hardware state is unknown, e.g. after sleep: the next `apply` writes everything.
    func forget() {
        applied = nil
    }

    /// Writes what differs from the last `apply`. `previous` and `current` are the snapshots before and at this
    /// event; nil when unreadable. `retryFailures`: a failed write is retried on the next `apply` instead of making
    /// its Feature unavailable.
    func apply(_ next: Actuation, previous: BatterySnapshot?, current: BatterySnapshot?, retryFailures: Bool) {
        if needsReverify(from: previous, to: current) || changed(\.chargeLimit, to: next) {
            write(.chargeLimit, retryFailures: retryFailures) {
                effectiveLimit = nil
                effectiveLimit = try hardware.setChargeLimit(next.chargeLimit)
                limitUnverified = current?.adapterConnected == false
                    && (next.chargeLimit ?? NativeLimit.powerUIMinimum) < NativeLimit.powerUIMinimum
            }
        }
        if changed(\.led, to: next) {
            write(.led, retryFailures: retryFailures) { try hardware.setLED(next.led) }
        }
        requestedLimit = next.chargeLimit
        applied = next
        if retryNextApply {
            applied = nil
            retryNextApply = false
        }
    }

    /// Hands the LED to the system unless it already has it. Leaves the Charge Limit as is.
    func releaseLED() {
        if applied?.led != .system { write(.led, retryFailures: false) { try hardware.setLED(.system) } }
        applied?.led = .system
    }

    /// A limit below 80 set while unplugged was returned unverified; the plug-in applies it, so it is set again to
    /// check. Only on the plug-in after such a set: the re-set is made plugged in, so it clears the flag and later
    /// plug-ins leave the limit alone.
    private func needsReverify(from previous: BatterySnapshot?, to current: BatterySnapshot?) -> Bool {
        previous?.adapterConnected == false && current?.adapterConnected == true && limitUnverified
    }

    private func changed<T: Equatable>(_ field: KeyPath<Actuation, T>, to next: Actuation) -> Bool {
        applied.map { $0[keyPath: field] != next[keyPath: field] } ?? true
    }

    /// Runs a hardware write unless the feature is already unavailable; a failure makes it unavailable, except with
    /// `retryFailures` and for a first `adapterCut`, where it is retried on the next `apply`.
    private func write(_ feature: Feature, retryFailures: Bool, _ operation: () throws -> Void) {
        guard !unavailable.contains(feature) else { return }
        do {
            try operation()
            if feature == .chargeLimit { adapterLeftCut = false }
        } catch HardwareError.adapterCut where !adapterLeftCut {
            // The next snapshot turns the adapter back on, so the write is retried then.
            adapterLeftCut = true
            retryNextApply = true
        } catch {
            if retryFailures {
                retryNextApply = true
            } else {
                unavailable.insert(feature)
            }
        }
    }
}

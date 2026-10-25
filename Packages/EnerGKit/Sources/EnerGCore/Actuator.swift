import Foundation

/// Writes an `Actuation` through `Hardware`, only the fields that changed or, for the LED, that macOS changed, and
/// keeps what the writes reported: the Charge Limit written and the Features whose writes failed. Whether the Charge
/// Limit took is judged by `limitCheck`, which can ask for it to be written again. Not thread-safe: call from the
/// Engine's serial context.
final class Actuator {
    private let hardware: any Hardware
    /// Last actuation written; nil means unknown, so everything is written.
    private var applied: Actuation?
    /// The Charge Limit last written successfully; nil when off, failed or not written yet.
    private var writtenLimit: Int?
    /// Features whose write failed; not written again until `reset`.
    private(set) var unavailable: Set<Feature> = []
    /// The last Charge Limit write left the adapter cut; a second one in a row makes it unavailable.
    private var adapterLeftCut = false
    /// A write is to be retried: the next `apply` re-asserts everything.
    private var retryNextApply = false
    private(set) var limitCheck = LimitCheck()

    init(hardware: any Hardware) {
        self.hardware = hardware
    }

    /// The Charge Limit in effect: the one written, or what the firmware holds when a lower one didn't take.
    var effectiveLimit: Int? {
        if case .unsupported(let held) = limitCheck.verdict { return held }
        return writtenLimit
    }

    /// Daemon launch: hardware state is unknown and every Feature is tried again.
    func reset() {
        applied = nil
        writtenLimit = nil
        unavailable = []
        adapterLeftCut = false
        limitCheck = LimitCheck()
    }

    /// Hardware state is unknown, e.g. after sleep: the next `apply` writes everything.
    func forget() {
        applied = nil
    }

    /// Writes what differs from the last `apply`, then lets `limitCheck` judge `snapshot` (read at `now`, before these
    /// writes; nil when unreadable). `retryFailures`: a failed write is retried on the next `apply` instead of making
    /// its Feature unavailable.
    func apply(_ next: Actuation, snapshot: BatterySnapshot?, now: Date, retryFailures: Bool) {
        if changed(\.chargeLimit, to: next) {
            writeLimit(next.chargeLimit, now: now, retryFailures: retryFailures)
        }
        let requested = unavailable.contains(.chargeLimit) ? nil : next.chargeLimit
        if limitCheck.observe(requested: requested, snapshot: snapshot, now: now) {
            writeLimit(next.chargeLimit, now: now, retryFailures: retryFailures)
        }
        if changed(\.led, to: next) || ledDrifted(from: next.led) {
            write(.led, retryFailures: retryFailures) { try hardware.setLED(next.led) }
        }
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

    private func writeLimit(_ limit: Int?, now: Date, retryFailures: Bool) {
        write(.chargeLimit, retryFailures: retryFailures) {
            writtenLimit = nil
            try hardware.setChargeLimit(limit)
            writtenLimit = limit
        }
        limitCheck.wrote(at: now)
    }

    /// macOS changed the LED on its own, e.g. a few seconds after an unplug. A system-driven LED reads as a colour,
    /// so `.system` is never checked; an unreadable LED counts as unchanged.
    private func ledDrifted(from wanted: LEDState) -> Bool {
        guard wanted != .system, !unavailable.contains(.led), let actual = hardware.readLED() else { return false }
        return actual != wanted
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

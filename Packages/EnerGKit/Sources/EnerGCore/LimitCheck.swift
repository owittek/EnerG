import Foundation

/// Judges from snapshots whether the requested Charge Limit took, and when to write it again. A write alone can't tell:
/// the smartcharging daemon applies a limit below 80 on its next % change or plug event (ADR 0001), and during
/// Calibration macOS ignores every limit and `CHLT` reads off. Not thread-safe: call from the Engine's serial context.
struct LimitCheck {
    enum Verdict: Equatable {
        /// Nothing to judge: no limit requested, unplugged, unreadable, or no settled read yet.
        case none
        case ok
        /// macOS ignores every limit for now (Calibration). Nothing is written: the limit applies once it ends.
        case calibrating
        /// `CHLT` holds another value; `observe` asks for a rewrite once the retry delay has passed.
        case mismatch
        /// A limit below 80 still reads as this value after a rewrite, so this value is in effect. No more timed
        /// rewrites: a plug-in or limit change starts fresh, and a wake's re-assert still writes it.
        case unsupported(Int)
    }

    /// A `CHLT` read this soon after a limit write or a plug-in can show the value from before it.
    static let settle: TimeInterval = 30
    /// Delay before the first rewrite of a mismatch; doubles per rewrite up to `maxRetry`. Not once unsupported.
    static let firstRetry: TimeInterval = 10 * 60
    static let maxRetry: TimeInterval = 160 * 60

    private(set) var verdict = Verdict.none
    /// The requested limit the verdict and retries belong to; nil while there is nothing to judge.
    private var judged: Int?
    /// Reads before this are not judged.
    private var settledAfter: Date?
    /// Rewrites made since the last match.
    private var retries = 0
    private var retryAt: Date?

    /// A limit write was made at `now`; reads in the next `settle` seconds keep the current verdict.
    mutating func wrote(at now: Date) {
        settledAfter = now + Self.settle
    }

    /// Updates the verdict from a snapshot read at `now`. `requested` is nil while no limit is asked for (off, paused,
    /// topping up, or unavailable). Returns true when the limit should be written again now; the caller then
    /// writes it and calls `wrote(at:)`.
    mutating func observe(requested: Int?, snapshot: BatterySnapshot?, now: Date) -> Bool {
        guard let requested, let snapshot, snapshot.adapterConnected else {
            startFresh(judging: nil)
            return false
        }
        if requested != judged {
            startFresh(judging: requested)
            settledAfter = max(settledAfter ?? now, now + Self.settle)
        }
        if let settledAfter, now < settledAfter { return false }
        guard let held = snapshot.firmwareLimit else {
            verdict = .calibrating
            retries = 0
            retryAt = nil
            return false
        }
        if held == requested {
            verdict = .ok
            retries = 0
            retryAt = nil
            return false
        }
        if retries > 0, requested < NativeLimit.powerUIMinimum {
            // Each rewrite may pulse the adapter: the override stays for the daemon, with no more timed rewrites.
            verdict = .unsupported(held)
            retryAt = nil
            return false
        }
        verdict = .mismatch
        guard let due = retryAt else {
            retryAt = now + min(Self.firstRetry * pow(2, Double(retries)), Self.maxRetry)
            return false
        }
        guard now >= due else { return false }
        retries += 1
        retryAt = nil
        return true
    }

    private mutating func startFresh(judging limit: Int?) {
        verdict = .none
        judged = limit
        retries = 0
        retryAt = nil
    }
}

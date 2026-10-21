/// The popover's side of the controls. Clicks change what the user wants at once; requests to energd go out one at a
/// time, polls included, and the latest click on a control wins. While a change settles, `displayed` shows the status
/// predicted for it instead of a reply that may still be stale. Use from one actor; time is passed in.
public struct Reconciler {
    /// One request sent to energd. Pass it back with its reply or failure.
    public struct Token: Equatable, Sendable {
        fileprivate let seq: Int
        fileprivate let isPoll: Bool
    }

    public enum FailureOutcome: Equatable, Sendable {
        /// From before a `reset`, or already answered: ignore it.
        case stale
        /// Wait a second, then send what `nextCommand` returns. Also returned for a poll, which isn't retried here.
        case retry
        /// energd stayed unreachable for `retryWindow`: every pending change was dropped.
        case gaveUp
    }

    /// How long failed changes are retried, from the first failure in a row, before they are dropped.
    public static let retryWindow: Duration = .seconds(10)

    /// How long the prediction stays once nothing is left to send, if no confirmed status agrees with it first.
    public static let settleCap: Duration = .seconds(6)

    /// Declared in send order.
    private enum Field: CaseIterable { case paused, limit, topUp, led }

    /// Per control, the value the user wants; nil follows what energd reports.
    private struct Wants: Equatable {
        var paused: Bool?
        var limit: Int?
        var topUp: Bool?
        var led: LEDMode?
    }

    private struct InFlight {
        let token: Token
        /// The field and the request sent for it; nil for a poll.
        let sent: (field: Field, request: Request)?
    }

    private struct Settle {
        /// The confirmed status at the first click; the band prediction keeps its charging state.
        let baseline: Status
        /// When nothing was left to send; nil while something is.
        var drainedAt: ContinuousClock.Instant? = nil
        /// A Pause, Charge Limit or Top Up request was sent, so replies may carry a stale charging state.
        var chargeWritten = false
    }

    private var confirmed: Status?
    private var wants = Wants()
    private var inFlight: InFlight?
    private var firstFailure: ContinuousClock.Instant?
    private var seq = 0
    /// Tokens up to this one are from before the last `reset`.
    private var resetSeq = 0
    private var settle: Settle?
    /// Shown from `closed` until a poll sent after it answers, a click or giving up.
    private var frozen: Status?
    private var closedSeq = 0

    public init() {}

    /// A click: `setPaused`, `setLimit`, `topUp`, `cancelTopUp` or `setLEDMode`; other requests are ignored, as is a
    /// click before the first status arrives. Pause also drops a wanted Top Up, as energd clears it.
    public mutating func want(_ request: Request, now: ContinuousClock.Instant) {
        guard let confirmed else { return }
        switch request {
        case .setPaused(let paused):
            wants.paused = paused
            if paused { wants.topUp = nil }
        case .setLimit(let limit): wants.limit = limit
        case .topUp: wants.topUp = true
        case .cancelTopUp: wants.topUp = false
        case .setLEDMode(let mode): wants.led = mode
        case .getStatus, .release: return
        }
        frozen = nil
        if settle.map({ expired($0, now) }) ?? true { settle = Settle(baseline: confirmed) }
        prune()
        updateSettle(now)
    }

    /// The next change to send, or nil while a request is in flight or nothing differs from the confirmed status.
    public mutating func nextCommand() -> (Request, Token)? {
        guard inFlight == nil, let confirmed else { return nil }
        for field in Field.allCases {
            guard let request = request(for: field, confirmed) else { continue }
            let token = issue(isPoll: false)
            inFlight = InFlight(token: token, sent: (field, request))
            if field != .led { settle?.chargeWritten = true }
            return (request, token)
        }
        return nil
    }

    /// A token for a `getStatus`, or nil while a request is in flight or a change waits to be sent.
    public mutating func beginPoll() -> Token? {
        guard inFlight == nil, !hasPendingChange else { return nil }
        let token = issue(isPoll: true)
        inFlight = InFlight(token: token, sent: nil)
        return token
    }

    /// A reply to a command or poll. Returns false for a token from before a `reset`, which changes nothing.
    @discardableResult
    public mutating func received(_ status: Status, for token: Token, now: ContinuousClock.Instant) -> Bool {
        guard token.seq > resetSeq else { return false }
        let own = inFlight?.token == token ? inFlight : nil
        if own != nil { inFlight = nil }
        confirmed = status
        firstFailure = nil
        // energd kept the old value for exactly what was sent (e.g. Top Up while unplugged): stop asking.
        if let sent = own?.sent, request(for: sent.field, status) == sent.request { clear(sent.field) }
        if token.isPoll, token.seq > closedSeq { frozen = nil }
        prune()
        // A want kept through a failure (e.g. Resume after a failed Pause) is sent again: show it as a prediction.
        if hasPendingChange, settle.map({ expired($0, now) }) ?? true { settle = Settle(baseline: status) }
        updateSettle(now)
        return true
    }

    /// The request for `token` didn't reach energd.
    public mutating func failed(_ token: Token, now: ContinuousClock.Instant) -> FailureOutcome {
        guard token.seq > resetSeq, inFlight?.token == token else { return .stale }
        inFlight = nil
        guard !token.isPoll else { return .retry }
        // A click since the send may have cancelled out the change: nothing to retry, the next poll decides.
        guard hasPendingChange else {
            firstFailure = nil
            updateSettle(now)
            return .retry
        }
        let first = firstFailure ?? now
        firstFailure = first
        guard first.duration(to: now) >= Self.retryWindow else { return .retry }
        wants = Wants()
        settle = nil
        frozen = nil
        firstFailure = nil
        return .gaveUp
    }

    /// A failed change is still wanted and waiting to be retried.
    public var waitingForHelper: Bool { firstFailure != nil && hasPendingChange }

    /// What the popover shows: the prediction while a change settles, else the confirmed status; from `closed` until
    /// a poll sent after it answers, a click or giving up, what was shown at `closed`. nil before the first status.
    public func displayed(now: ContinuousClock.Instant) -> Status? {
        if let frozen { return frozen }
        guard let confirmed else { return nil }
        guard let settle, !expired(settle, now) else { return confirmed }
        return prediction(confirmed, settle)
    }

    /// A change is settling, so polls should come faster.
    public func isSettling(now: ContinuousClock.Instant) -> Bool {
        settle.map { !expired($0, now) } ?? false
    }

    /// When the prediction gives way to the confirmed status unless one agrees first; nil while something is left to
    /// send or nothing is settling. May be in the past once the cap has passed without an event.
    public var settleDeadline: ContinuousClock.Instant? { settle?.drainedAt.map { $0 + Self.settleCap } }

    /// The popover closed: keep showing what it showed until a poll sent after this answers, since replies arriving
    /// meanwhile may be stale. A click or giving up ends it sooner.
    public mutating func closed(now: ContinuousClock.Instant) {
        frozen = displayed(now: now)
        closedSeq = seq
    }

    /// Forgets everything, e.g. after an uninstall; replies to earlier tokens are then stale.
    public mutating func reset() {
        let last = seq
        self = Reconciler()
        seq = last
        resetSeq = last
    }

    private var hasPendingChange: Bool {
        guard let confirmed else { return false }
        return Field.allCases.contains { request(for: $0, confirmed) != nil }
    }

    /// No change in flight and nothing differs from the confirmed status.
    private var queueEmpty: Bool { inFlight?.sent == nil && !hasPendingChange }

    /// Drops wants energd already reports, except the one in flight.
    private mutating func prune() {
        guard let confirmed else { return }
        for field in Field.allCases where inFlight?.sent?.field != field && request(for: field, confirmed) == nil {
            clear(field)
        }
        if queueEmpty { firstFailure = nil }
    }

    private func expired(_ settle: Settle, _ now: ContinuousClock.Instant) -> Bool {
        settle.drainedAt.map { $0.duration(to: now) >= Self.settleCap } ?? false
    }

    /// Notes when the queue emptied; ends the settle once nothing is left to send and the confirmed status agrees
    /// with the prediction, or at the cap.
    private mutating func updateSettle(_ now: ContinuousClock.Instant) {
        guard var settle, let confirmed else { return }
        guard queueEmpty else {
            settle.drainedAt = nil
            self.settle = settle
            return
        }
        if settle.drainedAt == nil { settle.drainedAt = now }
        let shown = prediction(confirmed, settle)
        let agrees = shown.state == confirmed.state && shown.stateLabel == confirmed.stateLabel
        self.settle = agrees || expired(settle, now) ? nil : settle
    }

    /// The confirmed status with the wanted settings applied. The charge state is re-derived once a Pause, Charge
    /// Limit or Top Up request has been sent, or while they differ from the confirmed status or the baseline; otherwise
    /// it stays as reported.
    private func prediction(_ confirmed: Status, _ settle: Settle) -> Status {
        var settings = confirmed.settings
        settings.paused = wants.paused ?? (confirmed.state == .paused)
        settings.chargeLimit = wants.limit ?? confirmed.settings.chargeLimit
        settings.ledMode = wants.led ?? confirmed.settings.ledMode
        let toppingUp = wants.topUp ?? confirmed.toppingUp
        let wanted = (settings.paused, settings.chargeLimit, toppingUp)
        let base = settle.baseline
        if !settle.chargeWritten,
           wanted == (confirmed.state == .paused, confirmed.settings.chargeLimit, confirmed.toppingUp),
           wanted == (base.state == .paused, base.settings.chargeLimit, base.toppingUp) {
            var shown = confirmed
            shown.settings.ledMode = settings.ledMode
            return shown
        }
        return confirmed.predicted(settings: settings, toppingUp: toppingUp,
                                   chargingBefore: base.snapshot?.isCharging ?? false)
    }

    /// The request that moves `field` from `confirmed` to what is wanted; nil when nothing is wanted or they match.
    /// Pause compares with the state, so it also ends a `release`.
    private func request(for field: Field, _ confirmed: Status) -> Request? {
        switch field {
        case .paused:
            guard let paused = wants.paused, paused != (confirmed.state == .paused) else { return nil }
            return .setPaused(paused)
        case .limit:
            guard let limit = wants.limit, limit != confirmed.settings.chargeLimit else { return nil }
            return .setLimit(limit)
        case .topUp:
            guard let topUp = wants.topUp, topUp != confirmed.toppingUp else { return nil }
            return topUp ? .topUp : .cancelTopUp
        case .led:
            guard let mode = wants.led, mode != confirmed.settings.ledMode else { return nil }
            return .setLEDMode(mode)
        }
    }

    private mutating func clear(_ field: Field) {
        switch field {
        case .paused: wants.paused = nil
        case .limit: wants.limit = nil
        case .topUp: wants.topUp = nil
        case .led: wants.led = nil
        }
    }

    private mutating func issue(isPoll: Bool) -> Token {
        seq += 1
        return Token(seq: seq, isPoll: isPoll)
    }
}

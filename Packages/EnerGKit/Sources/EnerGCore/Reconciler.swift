/// The popover's side of the controls. Clicks change what the user wants at once; requests to energd go out one at a
/// time, polls included, and the latest click on a control wins. Use from one actor; time is passed in.
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

    private var confirmed: Status?
    private var wants = Wants()
    private var inFlight: InFlight?
    private var firstFailure: ContinuousClock.Instant?
    private var seq = 0
    /// Tokens up to this one are from before the last `reset`.
    private var resetSeq = 0

    public init() {}

    /// A click: `setPaused`, `setLimit`, `topUp`, `cancelTopUp` or `setLEDMode`; other requests are ignored, as is a
    /// click before the first status arrives. Pause also drops a wanted Top Up, as energd clears it.
    public mutating func want(_ request: Request, now: ContinuousClock.Instant) {
        guard confirmed != nil else { return }
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
        prune()
    }

    /// The next change to send, or nil while a request is in flight or nothing differs from the confirmed status.
    public mutating func nextCommand() -> (Request, Token)? {
        guard inFlight == nil, let confirmed else { return nil }
        for field in Field.allCases {
            guard let request = request(for: field, confirmed) else { continue }
            let token = issue(isPoll: false)
            inFlight = InFlight(token: token, sent: (field, request))
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
        prune()
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
            return .retry
        }
        let first = firstFailure ?? now
        firstFailure = first
        guard first.duration(to: now) >= Self.retryWindow else { return .retry }
        wants = Wants()
        firstFailure = nil
        return .gaveUp
    }

    /// A failed change is still wanted and waiting to be retried.
    public var waitingForHelper: Bool { firstFailure != nil && hasPendingChange }

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

    /// No change in flight and nothing left to send.
    private var queueEmpty: Bool { inFlight?.sent == nil && wants == Wants() }

    /// Drops wants energd already reports, except the one in flight.
    private mutating func prune() {
        guard let confirmed else { return }
        for field in Field.allCases where inFlight?.sent?.field != field && request(for: field, confirmed) == nil {
            clear(field)
        }
        if queueEmpty { firstFailure = nil }
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

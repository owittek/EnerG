public enum Event: Equatable, Sendable {
    /// Daemon launch: re-applies all state.
    case start
    case tick
    case powerChanged
    case didWake
    case command(Request)
    /// Daemon shutdown: hands the LED to the system. Leaves the native Charge Limit and settings untouched.
    /// Send nothing after it except `.start`.
    case stop
}

/// Owns every charging rule. Feed it events; it writes only what changed through `Hardware`.
/// Not thread-safe: call from one serial context.
public final class Engine {
    public private(set) var settings: Settings
    private let hardware: any Hardware
    private var session = Session()
    /// Last actuation written; nil means unknown, so everything is written.
    private var applied: Actuation?
    private var snapshot: BatterySnapshot?
    /// What `setChargeLimit` reported in effect; nil when off, unavailable or not written yet.
    private var effectiveLimit: Int?
    /// Set while `.didWake` re-asserts the full state: a failed write is retried, not marked unavailable.
    private var wakeReassert = false
    /// A write failed during the wake re-assert; the next event re-asserts everything again.
    private var wakeReassertFailed = false

    public init(hardware: any Hardware, settings: Settings) {
        self.hardware = hardware
        self.settings = settings
    }

    @discardableResult
    public func handle(_ event: Event) -> Status {
        switch event {
        case .start:
            session = Session()
            applied = nil
            effectiveLimit = nil
        case .tick, .powerChanged:
            break
        case .stop:
            stop()
            return status()
        case .didWake:
            applied = nil   // hardware state after sleep is unknown: re-assert all of it
            wakeReassert = true
        case .command(let request):
            perform(request)
        }
        evaluate(countsWeakSample: event == .tick)
        wakeReassert = false
        return status()
    }

    private func perform(_ request: Request) {
        switch request {
        case .getStatus:
            break
        case .setLimit(let limit):
            if Settings.allowedLimits.contains(limit) { settings.chargeLimit = limit }
        case .topUp:
            guard !paused else { return }
            session.toppingUp = true
        case .cancelTopUp:
            session.toppingUp = false
        case .setLEDMode(let mode):
            settings.ledMode = mode
        case .setPaused(let paused):
            settings.paused = paused
            session.released = false
        case .release:
            session.released = true   // not persisted: a reinstall must not start paused
        }
    }

    /// Pause, or released before uninstall.
    private var paused: Bool { Policy.isPaused(settings, session) }

    private func evaluate(countsWeakSample: Bool) {
        do {
            snapshot = try hardware.snapshot()
        } catch {
            // Can't see the battery: Pause still clears every running mode and hands back; otherwise keep everything as is.
            snapshot = nil
            if paused {
                Policy.clearForPause(&session)
                apply(.released)
            }
            return
        }
        let current = snapshot!
        Policy.update(settings: settings, snapshot: current, countsWeakSample: countsWeakSample, session: &session)
        apply(Policy.actuation(settings: settings, snapshot: current, session: session))
    }

    private func apply(_ next: Actuation) {
        if changed(\.chargeLimit, to: next) {
            write(.chargeLimit) {
                effectiveLimit = nil
                effectiveLimit = try hardware.setChargeLimit(next.chargeLimit)
            }
        }
        if changed(\.led, to: next) { write(.led) { try hardware.setLED(next.led) } }
        applied = next
        if wakeReassertFailed {
            applied = nil
            wakeReassertFailed = false
        }
    }

    /// A kickstart can't be told apart from a bootout, so the native Charge Limit stays as is.
    private func stop() {
        if applied?.led != .system { write(.led) { try hardware.setLED(.system) } }
        applied?.led = .system
    }

    private func changed<T: Equatable>(_ field: KeyPath<Actuation, T>, to next: Actuation) -> Bool {
        applied.map { $0[keyPath: field] != next[keyPath: field] } ?? true
    }

    /// Runs a hardware write unless the feature is already unavailable; a failure makes it unavailable,
    /// except during the wake re-assert, where it is retried on the next event.
    private func write(_ feature: Feature, _ operation: () throws -> Void) {
        guard !session.unavailable.contains(feature) else { return }
        do {
            try operation()
        } catch {
            if wakeReassert {
                wakeReassertFailed = true
            } else {
                session.unavailable.insert(feature)
            }
        }
    }

    private func status() -> Status {
        var warnings: [Warning] = []
        if session.weakSamples >= 2 { warnings.append(.weakAdapter) }
        if let effective = effectiveLimit, let requested = applied?.chargeLimit, effective > requested {
            warnings.append(.lowLimitUnsupported)
        }
        warnings += Feature.allCases.filter(session.unavailable.contains).map(Warning.unavailable)
        if snapshot == nil { warnings.append(.batteryUnreadable) }
        return Status(state: state(), settings: settings, snapshot: snapshot,
                      effectiveLimit: effectiveLimit, toppingUp: session.toppingUp, warnings: warnings)
    }

    private func state() -> ChargeState {
        if paused { return .paused }
        guard let snapshot else { return .unknown }
        if session.toppingUp { return .toppingUp }
        if !snapshot.adapterConnected { return .onBattery }
        return snapshot.isCharging ? .charging : .atLimit
    }
}

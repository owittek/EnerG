public enum Event: Equatable, Sendable {
    /// Daemon launch: re-applies all state.
    case start
    case tick
    case powerChanged
    case didWake
    case command(Request)
    /// Daemon shutdown: turns a cut adapter back on and hands the LED to the system. Leaves the native Charge Limit and settings
    /// untouched. Send nothing after it except `.start`.
    case stop
}

/// Owns every charging rule. Feed it events; it writes only what changed through `Hardware`.
/// Not thread-safe: call from one serial context.
public final class Engine {
    public private(set) var settings: Settings
    private let hardware: any Hardware
    private let actuator: Actuator
    private var session = Session()
    private var snapshot: BatterySnapshot?

    public init(hardware: any Hardware, settings: Settings) {
        self.hardware = hardware
        self.actuator = Actuator(hardware: hardware)
        self.settings = settings
    }

    @discardableResult
    public func handle(_ event: Event) -> Status {
        switch event {
        case .start:
            session = Session()
            actuator.reset()
        case .tick, .powerChanged:
            break
        case .stop:
            stop()
            return status()
        case .didWake:
            actuator.forget()   // hardware state after sleep is unknown: re-assert all of it
        case .command(let request):
            perform(request)
        }
        // During the wake re-assert a failed write is retried, not marked unavailable.
        evaluate(retryFailures: event == .didWake)
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

    private func evaluate(retryFailures: Bool) {
        let previous = snapshot
        let current: BatterySnapshot
        do {
            current = try hardware.snapshot()
        } catch {
            // Can't see the battery: Pause still clears every running mode and hands back; otherwise keep everything as is.
            snapshot = nil
            if paused {
                Policy.clearForPause(&session)
                actuator.apply(.released, previous: previous, current: nil, retryFailures: retryFailures)
            }
            return
        }
        snapshot = current
        Policy.update(settings: settings, snapshot: current, session: &session)
        actuator.apply(Policy.actuation(settings: settings, snapshot: current, session: session),
                       previous: previous, current: current, retryFailures: retryFailures)
    }

    /// A kickstart can't be told apart from a bootout, so the native Charge Limit stays as is.
    private func stop() {
        _ = try? hardware.snapshot()   // an adapter left cut by the last set is turned back on there
        actuator.releaseLED()
    }

    private func status() -> Status {
        var warnings: [Warning] = []
        if actuator.lowLimitUnsupported { warnings.append(.lowLimitUnsupported) }
        warnings += Feature.allCases.filter(actuator.unavailable.contains).map(Warning.unavailable)
        if snapshot == nil { warnings.append(.batteryUnreadable) }
        return Status(state: state(), settings: settings, snapshot: snapshot,
                      effectiveLimit: actuator.effectiveLimit, toppingUp: session.toppingUp, warnings: warnings)
    }

    private func state() -> ChargeState {
        .derive(paused: paused, toppingUp: session.toppingUp, snapshot: snapshot,
                effectiveLimit: actuator.effectiveLimit)
    }
}

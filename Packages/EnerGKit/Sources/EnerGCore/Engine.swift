public enum Event: Equatable, Sendable {
    /// Daemon launch: re-enables the adapter before anything else, then re-applies all state.
    case start
    case tick
    case powerChanged
    /// Must be handled before acknowledging sleep; returns with the adapter enabled.
    case willSleep
    case didWake
    case lid(closed: Bool)
    case command(Request)
    /// Daemon shutdown: ends any Discharge, turns the adapter on, hands the LED to the system and
    /// releases the sleep assertion. Leaves the native Charge Limit and settings untouched.
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
            _ = enableAdapter()
        case .tick, .powerChanged:
            break
        case .stop:
            stop()
            return status()
        case .willSleep:
            session.sleeping = true
            session.dischargeTarget = nil
        case .didWake:
            session.sleeping = false
            applied = nil   // hardware state after sleep is unknown: re-assert all of it
            wakeReassert = true
        case .lid(let closed):
            session.lidClosed = closed
            if closed { session.dischargeTarget = nil }
        case .command(let request):
            perform(request)
        }
        evaluate(countsWeakSample: event == .tick || event == .powerChanged)
        wakeReassert = false
        return status()
    }

    private func perform(_ request: Request) {
        switch request {
        case .getStatus:
            break
        case .setLimit(let limit):
            if Settings.allowedLimits.contains(limit) { settings.chargeLimit = limit }
        case .discharge(let target):
            guard (5...100).contains(target), session.canStartDischarge, !paused,
                  snapshot?.adapterConnected == true else { return }
            session.toppingUp = false
            session.autoSuppressed = false
            session.dischargeTarget = target
        case .cancelDischarge:
            session.dischargeTarget = nil
            session.autoSuppressed = true
        case .topUp:
            guard !paused else { return }
            session.toppingUp = true
            session.dischargeTarget = nil
        case .cancelTopUp:
            session.toppingUp = false
        case .setLEDMode(let mode):
            settings.ledMode = mode
        case .setAutoDischarge(let on):
            settings.autoDischarge = on
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
            // Can't see the battery: stop any Discharge, keep everything else as is.
            snapshot = nil
            session.dischargeTarget = nil
            if paused {
                apply(.released, snapshot: nil)
            } else if var safe = applied {
                safe.adapterEnabled = true
                safe.preventSleep = false
                apply(safe, snapshot: nil)
            } else {
                _ = enableAdapter()
            }
            return
        }
        let current = snapshot!
        Policy.update(settings: settings, snapshot: current, countsWeakSample: countsWeakSample, session: &session)
        apply(Policy.actuation(settings: settings, snapshot: current, session: session), snapshot: current)
    }

    private func apply(_ desired: Actuation, snapshot: BatterySnapshot?) {
        var next = desired
        var enableFailed = false
        var reapplyLimit = false
        if changed(\.adapterEnabled, to: next) {
            if next.adapterEnabled {
                enableFailed = !enableAdapter()
                // Adapter back on above the native limit after a cut, or after a start or wake where a cut
                // may still be in place: macOS stays on battery until the limit is disabled and set again.
                if !enableFailed, applied?.adapterEnabled != true,
                   let limit = next.chargeLimit, let snapshot, snapshot.percent > limit {
                    reapplyLimit = true
                }
            } else {
                write(.discharge) { try hardware.setAdapter(enabled: false) }
                // Cutting the adapter failed: the Discharge was dropped, so derive the rest again.
                if session.dischargeTarget == nil, let snapshot {
                    next = Policy.actuation(settings: settings, snapshot: snapshot, session: session)
                }
            }
        }
        var limitLeftOff = false
        if reapplyLimit {
            write(.chargeLimit) {
                try hardware.setChargeLimit(nil)
                // Disabled but not set again: record it as off so the next evaluate sets it the normal way,
                // which latches unavailable only if that fails too.
                do { try hardware.setChargeLimit(next.chargeLimit) } catch { limitLeftOff = true }
            }
        } else if changed(\.chargeLimit, to: next) {
            write(.chargeLimit) { try hardware.setChargeLimit(next.chargeLimit) }
        }
        if changed(\.led, to: next) { write(.led) { try hardware.setLED(next.led) } }
        if changed(\.preventSleep, to: next) { hardware.setPreventSleep(next.preventSleep) }
        applied = next
        if limitLeftOff { applied?.chargeLimit = nil }
        // Re-enable failed: record the adapter as still off so the next evaluate retries.
        if enableFailed { applied?.adapterEnabled = false }
        if wakeReassertFailed {
            applied = nil
            wakeReassertFailed = false
        }
    }

    /// A kickstart can't be told apart from a bootout, so the native Charge Limit stays as is.
    private func stop() {
        session.dischargeTarget = nil
        let enabled = enableAdapter()   // always written: the daemon may not run again to retry it
        if applied?.led != .system { write(.led) { try hardware.setLED(.system) } }
        if applied?.preventSleep != false { hardware.setPreventSleep(false) }
        applied?.adapterEnabled = enabled
        applied?.led = .system
        applied?.preventSleep = false
    }

    /// Turning the adapter on is the safe direction: never skipped, never marks a feature unavailable.
    private func enableAdapter() -> Bool {
        do {
            try hardware.setAdapter(enabled: true)
            return true
        } catch {
            return false
        }
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
            if feature == .discharge { session.dischargeTarget = nil }
        }
    }

    private func status() -> Status {
        var warnings: [Warning] = []
        if session.weakSamples >= 2 { warnings.append(.weakAdapter) }
        warnings += Feature.allCases.filter(session.unavailable.contains).map(Warning.unavailable)
        if snapshot == nil { warnings.append(.batteryUnreadable) }
        return Status(state: state(), settings: settings, snapshot: snapshot,
                      dischargeTarget: session.dischargeTarget, toppingUp: session.toppingUp, warnings: warnings)
    }

    private func state() -> ChargeState {
        if paused { return .paused }
        guard let snapshot else { return .unknown }
        if session.dischargeTarget != nil { return .discharging }
        if session.toppingUp { return .toppingUp }
        if !snapshot.adapterConnected { return .onBattery }
        return snapshot.isCharging ? .charging : .atLimit
    }
}

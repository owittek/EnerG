import AppKit
import OSLog
import Observation
import ServiceManagement
import EnerGCore

@MainActor @Observable
final class AppModel {
    /// What the popover shows: the predicted status while a change settles, else the last reply. nil before the first.
    private(set) var status: Status?
    /// A change couldn't reach the helper and is being retried.
    private var waitingForHelper = false
    var helper: SMAppService.Status = HelperInstaller.status
    /// The one problem the popover shows, if anything is wrong.
    var problem: Problem? {
        Problem.shown(failure: failure,
                      connection: waitingForHelper ? .waitingForHelper : unreachable ? .helperUnreachable : nil)
    }
    var alDenteRunning = false
    var launchAtLogin = HelperInstaller.launchAtLogin

    private let log = Logger(subsystem: "app.energ", category: "app")
    /// A failed click or a dropped change; cleared when the user starts any action. A dropped change also clears once
    /// energd answers again.
    private var failure: Problem?
    /// Polls can't reach energd; cleared by an applied reply, or when the helper isn't enabled or is unregistered.
    private var unreachable = false
    private let client = DaemonClient()
    private var reconciler = Reconciler()
    private var polling: Task<Void, Never>?
    /// Sends queued changes; keeps running while the popover is closed.
    private var sender: Task<Void, Never>?
    private var settleTimer: Task<Void, Never>?
    private var lastAlDenteScan: ContinuousClock.Instant?
    /// While `uninstallHelper` runs, clicks are ignored and no queued change is sent, so none lands after `release`.
    private var uninstalling = false

    init() {
        // Launch at login defaults to on, once.
        let key = "launchAtLoginInitialized"
        if !UserDefaults.standard.bool(forKey: key) {
            do { try HelperInstaller.setLaunchAtLogin(true) } catch { fail(.launchAtLoginFailed, error) }
            UserDefaults.standard.set(true, forKey: key)
            launchAtLogin = HelperInstaller.launchAtLogin
        }
    }

    func startPolling() {
        polling?.cancel()
        lastAlDenteScan = nil
        polling = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: reconciler.isSettling(now: .now) ? .milliseconds(500) : .seconds(2))
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
        reconciler.closed(now: .now)
    }

    func refresh() async {
        helper = HelperInstaller.status
        let now = ContinuousClock.now
        if lastAlDenteScan.map({ $0.duration(to: now) >= .seconds(10) }) ?? true {
            lastAlDenteScan = now
            // ~700 proc_pidpath calls: keep them off the main actor.
            let helperRunning = await Task.detached {
                Self.isProcessRunning(executable: "com.apphousekitchen.aldente-pro.helper")
            }.value
            alDenteRunning = helperRunning || NSWorkspace.shared.runningApplications
                .contains { $0.bundleIdentifier == "com.apphousekitchen.aldente-pro" }
        }
        guard helper == .enabled else {
            reconciler.reset()
            publish()
            unreachable = false
            return
        }
        // Closed meanwhile: a poll now would end the hold on what was shown.
        guard !Task.isCancelled, let token = reconciler.beginPoll() else { return }
        do {
            let new = try await client.send(.getStatus)
            if reconciler.received(new, for: token, now: .now) { reached() }
        } catch {
            if reconciler.failed(token, now: .now) != .stale {
                // Log once per outage, not on every failed poll.
                if !unreachable {
                    log.error("status poll failed: \(String(describing: error), privacy: .public)")
                }
                unreachable = true
            }
        }
        publish()
        pump()
    }

    /// The Retry button: an action like any click, so it clears a failure before polling again.
    func retry() async {
        failure = nil
        await refresh()
    }

    /// A user click: shows the result at once and queues the request; the latest click on a control wins.
    func change(_ request: Request) {
        guard !uninstalling else { return }
        failure = nil
        reconciler.want(request, now: .now)
        publish()
        pump()
    }

    /// Sends queued changes one at a time until none is left, a poll is in flight or an uninstall runs; `refresh`
    /// restarts it then.
    private func pump() {
        guard sender == nil else { return }
        sender = Task {
            while !uninstalling, let next = reconciler.nextCommand() {
                let (request, token) = next
                do {
                    let new = try await client.send(request)
                    if reconciler.received(new, for: token, now: .now) { reached() }
                } catch {
                    log.error("""
                        \(String(describing: request), privacy: .public) failed: \
                        \(String(describing: error), privacy: .public)
                        """)
                    switch reconciler.failed(token, now: .now) {
                    case .retry:
                        publish()
                        try? await Task.sleep(for: .seconds(1))
                    case .gaveUp:
                        failure = .changeNotApplied
                    case .stale:
                        break
                    }
                }
                publish()
            }
            sender = nil
        }
    }

    /// Copies what the Reconciler shows, and wakes again at the settle deadline, when that can change on its own.
    private func publish() {
        let now = ContinuousClock.now
        let shown = reconciler.displayed(now: now)
        if shown != status { status = shown }
        if reconciler.waitingForHelper != waitingForHelper { waitingForHelper = reconciler.waitingForHelper }
        settleTimer?.cancel()
        guard let deadline = reconciler.settleDeadline, deadline > now else { return }
        settleTimer = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { publish() }
        }
    }

    /// Shows `problem` and logs the underlying error, which the popover doesn't show.
    private func fail(_ problem: Problem, _ error: any Error) {
        log.error("\(String(describing: problem), privacy: .public): \(String(describing: error), privacy: .public)")
        failure = problem
    }

    /// energd answered: it is reachable, so a dropped change no longer needs saying.
    private func reached() {
        unreachable = false
        if failure == .changeNotApplied { failure = nil }
    }

    func installHelper() {
        failure = nil
        do {
            try HelperInstaller.register()
        } catch {
            // register() throws "Operation not permitted" while the daemon awaits approval in Login Items; that is the normal first-install path, not a failure.
            let current = HelperInstaller.status
            if current != .requiresApproval && current != .enabled {
                fail(.installFailed, error)
            }
        }
        helper = HelperInstaller.status
        if helper == .requiresApproval { HelperInstaller.openApproval() }
    }

    /// `skipRelease`: "Uninstall Anyway" after a failed release. If energd is still running, its SIGTERM stop
    /// turns the adapter on and hands the LED back; if not, they stay as last set. The native Charge Limit may stay on.
    func uninstallHelper(skipRelease: Bool = false) async {
        failure = nil
        // Holds back new and queued changes; one already in flight can't be recalled and may still land.
        uninstalling = true
        defer { uninstalling = false }
        // Never unregister a daemon that may still hold the adapter off or the LED forced.
        if !skipRelease, HelperInstaller.status == .enabled {
            do {
                _ = try await client.send(.release)
            } catch {
                fail(.releaseFailed, error)
                // Still installed: queued changes resume.
                uninstalling = false
                pump()
                return
            }
        }
        do {
            try await HelperInstaller.unregister()
            unreachable = false
        } catch {
            fail(.uninstallFailed, error)
        }
        // Drop queued changes and any reply still in flight.
        reconciler.reset()
        helper = HelperInstaller.status
        publish()
    }

    /// Looks for a process by executable name across all users. proc_name fails for other users'
    /// processes when unprivileged (and truncates long names); proc_pidpath doesn't.
    nonisolated private static func isProcessRunning(executable: String) -> Bool {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return false }
        var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(count)).contains { pid in
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            guard length > 0 else { return false }
            return String(decoding: path.prefix(Int(length)), as: UTF8.self).hasSuffix("/" + executable)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        failure = nil
        do { try HelperInstaller.setLaunchAtLogin(on) } catch { fail(.launchAtLoginFailed, error) }
        launchAtLogin = HelperInstaller.launchAtLogin
    }

    /// Runs the button of the problem notice.
    func resolve(_ action: ProblemAction) {
        switch action {
        case .uninstallAnyway: Task { await uninstallHelper(skipRelease: true) }
        case .openLoginItems: HelperInstaller.openApproval()
        }
    }
}

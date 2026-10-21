import AppKit
import Observation
import ServiceManagement
import EnerGCore

@MainActor @Observable
final class AppModel {
    var status: Status?
    var helper: SMAppService.Status = HelperInstaller.status
    /// XPC failure; cleared only by an applied successful reply.
    var daemonError: String?
    /// Install/uninstall/launch-at-login failure; cleared when the user starts any action.
    var actionError: String? {
        didSet { if actionError == nil { offersUninstallAnyway = false } }
    }
    /// `release` failed during uninstall: the notice offers to unregister without it.
    var offersUninstallAnyway = false
    var alDenteRunning = false
    var launchAtLogin = HelperInstaller.launchAtLogin

    private let client = DaemonClient()
    private var polling: Task<Void, Never>?
    private var lastAlDenteScan: ContinuousClock.Instant?
    private var requestSeq = 0
    private var appliedSeq = 0

    init() {
        // Launch at login defaults to on, once.
        let key = "launchAtLoginInitialized"
        if !UserDefaults.standard.bool(forKey: key) {
            do { try HelperInstaller.setLaunchAtLogin(true) } catch {
                actionError = "Couldn't turn on Launch at Login: \(error.localizedDescription)"
            }
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
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        polling?.cancel()
        polling = nil
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
            status = nil
            daemonError = nil
            return
        }
        await send(.getStatus)
    }

    /// User-initiated request: clears the previous action error first.
    func perform(_ request: Request) async {
        actionError = nil
        await send(request)
    }

    func send(_ request: Request) async {
        requestSeq += 1
        let seq = requestSeq
        do {
            let new = try await client.send(request)
            guard seq > appliedSeq else { return }
            appliedSeq = seq
            status = new
            daemonError = nil
        } catch {
            guard seq > appliedSeq else { return }
            appliedSeq = seq
            daemonError = "Helper not reachable: \(error.localizedDescription)"
        }
    }

    func installHelper() {
        actionError = nil
        do {
            try HelperInstaller.register()
        } catch {
            // register() throws "Operation not permitted" while the daemon awaits approval in Login Items; that is the normal first-install path, not a failure.
            let current = HelperInstaller.status
            if current != .requiresApproval && current != .enabled {
                actionError = "Install failed: \(error.localizedDescription)"
            }
        }
        helper = HelperInstaller.status
        if helper == .requiresApproval { HelperInstaller.openApproval() }
    }

    /// `skipRelease`: "Uninstall Anyway" after a failed release. If energd is still running, its SIGTERM stop
    /// turns the adapter on and hands the LED back; if not, they stay as last set. The native Charge Limit may stay on.
    func uninstallHelper(skipRelease: Bool = false) async {
        actionError = nil
        // Never unregister a daemon that may still hold the adapter off or the LED forced.
        if !skipRelease, HelperInstaller.status == .enabled {
            do {
                _ = try await client.send(.release)
            } catch {
                actionError = "Couldn't release charging control, so the helper wasn't uninstalled: "
                    + "\(error.localizedDescription). Uninstall Anyway removes the helper without handing "
                    + "charging back first. If the helper is still running, it restores the adapter and LED "
                    + "as it stops; if not, they may stay as last set. The native Charge Limit may stay on."
                offersUninstallAnyway = true
                return
            }
        }
        do {
            try await HelperInstaller.unregister()
            daemonError = nil
        } catch {
            actionError = "Uninstall failed: \(error.localizedDescription)"
        }
        // Drop any poll reply still in flight.
        requestSeq += 1
        appliedSeq = requestSeq
        helper = HelperInstaller.status
        status = nil
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
        actionError = nil
        do { try HelperInstaller.setLaunchAtLogin(on) } catch { actionError = error.localizedDescription }
        launchAtLogin = HelperInstaller.launchAtLogin
    }
}

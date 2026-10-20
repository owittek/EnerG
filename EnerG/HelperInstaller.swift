import ServiceManagement
import EnerGCore

/// Registers energd with launchd and manages launch-at-login for the app.
/// MainActor because SMAppService is not Sendable.
@MainActor
enum HelperInstaller {
    static let daemon = SMAppService.daemon(plistName: DaemonID.plistName)

    static var status: SMAppService.Status { daemon.status }

    static func register() throws { try daemon.register() }

    static func unregister() async throws { try await daemon.unregister() }

    static func openApproval() { SMAppService.openSystemSettingsLoginItems() }

    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setLaunchAtLogin(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

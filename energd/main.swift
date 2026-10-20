import Foundation
import OSLog
import XPC
import EnerGCore
import EnerGMac

let log = Logger(subsystem: "app.energ", category: "energd")
let store = SettingsStore(url: URL(filePath: "/Library/Application Support/EnerG/settings.json"))

func makeHardware() -> MacHardware {
    do {
        return try MacHardware()
    } catch {
        log.fault("AppleSMC unavailable: \(String(describing: error), privacy: .public)")
        exit(1)
    }
}
let hardware = makeHardware()

let host = EngineHost(engine: Engine(hardware: hardware, settings: store.load()), store: store)

// launchd sends SIGTERM on bootout, shutdown, kickstart -k and when EnerG is switched off in Login Items.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { host.shutdown(exitCode: 0) }
sigterm.resume()

// Created before `.start`, so a listener failure exits without having touched the hardware.
func makeListener() -> XPCListener {
    do {
        // Only EnerG.app may connect.
        return try XPCListener(service: DaemonID.machService,
                               requirement: .isFromSameTeam(andMatchesSigningIdentifier: "app.energ.EnerG")) { request in
            request.accept(incomingMessageHandler: { (message: Request) -> (any Encodable)? in
                host.handle(.command(message))
            })
        }
    } catch {
        log.fault("XPC listener failed: \(String(describing: error), privacy: .public)")
        exit(1)
    }
}
let listener = makeListener()

host.handle(.start)

let events = SystemEvents(host: host)
if !events.start() {
    host.shutdown(exitCode: 1)   // KeepAlive relaunches energd
}

log.info("energd started")
withExtendedLifetime((listener, events, sigterm)) { RunLoop.main.run() }

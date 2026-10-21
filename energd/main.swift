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

/// Decodes each request itself, so a malformed message is logged and its session cancelled
/// (the client's reply handler then gets an error) instead of being left to the typed overlay.
struct RequestHandler: XPCPeerHandler {
    let session: XPCSession

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        do {
            return host.handle(.command(try message.decode(as: Request.self)))
        } catch {
            log.error("undecodable request: \(String(describing: error), privacy: .public)")
            session.cancel(reason: "undecodable request")
            return nil
        }
    }
}

// Created before `.start`, so a listener failure exits without having touched the hardware.
func makeListener() -> XPCListener {
    do {
        // Only EnerG.app may connect.
        return try XPCListener(service: DaemonID.machService,
                               requirement: .isFromSameTeam(andMatchesSigningIdentifier: "app.energ.EnerG")) { request in
            request.accept { session in RequestHandler(session: session) }
        }
    } catch {
        log.fault("XPC listener failed: \(String(describing: error), privacy: .public)")
        exit(1)
    }
}
let listener = makeListener()

// Its snapshot turns a cut adapter back on before the limit is written (MacHardware).
host.handle(.start)

let events = SystemEvents(host: host)
if !events.start() {
    host.shutdown(exitCode: 1)   // KeepAlive relaunches energd
}

log.info("energd started")
withExtendedLifetime((listener, events, sigterm)) { RunLoop.main.run() }

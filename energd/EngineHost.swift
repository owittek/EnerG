import Foundation
import OSLog
import EnerGCore

/// Serialises every Engine call onto one queue (XPC and IOKit callbacks arrive on
/// different threads) and persists settings whenever a call changed them.
final class EngineHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.energ.engine")
    private let engine: Engine
    private let store: SettingsStore
    private let log = Logger(subsystem: "app.energ", category: "energd")

    init(engine: Engine, store: SettingsStore) {
        self.engine = engine
        self.store = store
    }

    @discardableResult
    func handle(_ event: Event) -> Status {
        queue.sync {
            let before = engine.settings
            let status = engine.handle(event)
            if engine.settings != before {
                do { try store.save(engine.settings) } catch {
                    log.error("saving settings failed: \(String(describing: error), privacy: .public)")
                }
            }
            return status
        }
    }

    /// Hands the adapter, LED and sleep assertion back to macOS, then exits. Runs on the engine
    /// queue so no XPC or IOKit event can re-apply state between the stop and the exit.
    func shutdown(exitCode: Int32) -> Never {
        queue.sync {
            engine.handle(.stop)
            log.info("energd stopped (exit \(exitCode))")
            exit(exitCode)
        }
    }
}

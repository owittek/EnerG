import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import OSLog

// IOKit message constants are function-like macros that Swift does not import.
private let messageCanSystemSleep: natural_t = 0xE000_0270
private let messageSystemWillSleep: natural_t = 0xE000_0280
private let messageSystemHasPoweredOn: natural_t = 0xE000_0300

/// Feeds power-source, sleep/wake and timer events into the EngineHost.
/// Call `start()` on the main thread; callbacks arrive on the main run loop.
final class SystemEvents {
    private let host: EngineHost
    private let log = Logger(subsystem: "app.energ", category: "energd")
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var sleepNotifier: io_object_t = 0
    private var timer: Timer?

    init(host: EngineHost) { self.host = host }

    /// Registers every source. Returns false, after logging a fault, if sleep/wake
    /// notifications can't be registered; the caller must then stop and exit.
    func start() -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()

        // Plug, unplug and percentage changes.
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            Unmanaged<SystemEvents>.fromOpaque(context!).takeUnretainedValue().host.handle(.powerChanged)
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        // Sleep and wake.
        rootPort = IORegisterForSystemPower(context, &notifyPort, { context, _, type, argument in
            Unmanaged<SystemEvents>.fromOpaque(context!).takeUnretainedValue().power(type, argument)
        }, &sleepNotifier)
        guard rootPort != 0, let notifyPort else {
            log.fault("IORegisterForSystemPower failed")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [host] _ in host.handle(.tick) }
        return true
    }

    private func power(_ type: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case messageCanSystemSleep, messageSystemWillSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case messageSystemHasPoweredOn:
            host.handle(.didWake)
        default:
            break
        }
    }
}

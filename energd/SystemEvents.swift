import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import OSLog

// IOKit message constants are function-like macros that Swift does not import.
private let messageCanSystemSleep: natural_t = 0xE000_0270
private let messageSystemWillSleep: natural_t = 0xE000_0280
private let messageSystemHasPoweredOn: natural_t = 0xE000_0300
private let messageClamshellStateChange: natural_t = 0xE003_4100

/// Feeds power-source, sleep/wake, lid and timer events into the EngineHost.
/// Call `start()` on the main thread; callbacks arrive on the main run loop.
final class SystemEvents {
    private let host: EngineHost
    private let log = Logger(subsystem: "app.energ", category: "energd")
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var sleepNotifier: io_object_t = 0
    private var lidNotifier: io_object_t = 0
    private var timer: Timer?

    init(host: EngineHost) { self.host = host }

    /// Registers every source. Returns false, after logging a fault, if sleep/wake or lid
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

        // Lid (clamshell) changes, plus the current state.
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else {
            log.fault("IOPMrootDomain not found")
            return false
        }
        defer { IOObjectRelease(rootDomain) }
        let kr = IOServiceAddInterestNotification(notifyPort, rootDomain, kIOGeneralInterest, { context, _, type, argument in
            guard type == messageClamshellStateChange else { return }
            let closed = (UInt(bitPattern: argument) & 1) != 0
            Unmanaged<SystemEvents>.fromOpaque(context!).takeUnretainedValue().host.handle(.lid(closed: closed))
        }, context, &lidNotifier)
        guard kr == KERN_SUCCESS else {
            log.fault("lid notification failed: \(kr)")
            return false
        }
        let closed = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
        host.handle(.lid(closed: closed))

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [host] _ in host.handle(.tick) }
        return true
    }

    private func power(_ type: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case messageCanSystemSleep:
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case messageSystemWillSleep:
            host.handle(.willSleep)   // re-enables the adapter synchronously
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case messageSystemHasPoweredOn:
            host.handle(.didWake)
        default:
            break
        }
    }
}

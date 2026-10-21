import Foundation
import CPlatform
import EnerGCore
import EnerGMac

let usage = "usage: energ-smoke status | get-limit | adapter on|off | led system|off|green|orange | limit <80-100>|off"
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? ""
let argument = args.count > 1 ? args[1] : ""

do {
    let hw = try MacHardware()
    switch (command, argument) {
    case ("status", _):
        print(try hw.snapshot())
    case ("get-limit", _):
        var limit: UInt8 = 0
        var enabled = false
        let rc = powerui_get_limit(&limit, &enabled)
        guard rc == 0 else { throw rc == -1 ? HardwareError.frameworkUnavailable : HardwareError.io(rc) }
        print(enabled ? "\(limit)" : "off")
    case ("adapter", "on"):
        try hw.setAdapter(enabled: true)
    case ("adapter", "off"):
        try hw.setAdapter(enabled: false)
    case ("led", _):
        guard let state = LEDState(rawValue: argument) else { print(usage); exit(2) }
        try hw.setLED(state)
    case ("limit", "off"):
        _ = try hw.setChargeLimit(nil)
    case ("limit", _):
        guard let limit = Int(argument), (0...100).contains(limit) else { print(usage); exit(2) }
        _ = try hw.setChargeLimit(limit)
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

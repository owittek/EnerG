import Foundation
import CPlatform
import EnerGCore
import EnerGMac

let usage = "usage: energ-smoke status | get-limit | adapter on|off | led system|off|green|orange|blinkSlow | limit <80-100>|off"
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
        guard powerui_get_limit(&limit, &enabled) == 0 else { throw HardwareError.frameworkUnavailable }
        print(enabled ? "\(limit)" : "off")
    case ("adapter", "on"):
        try hw.setAdapter(enabled: true)
    case ("adapter", "off"):
        try hw.setAdapter(enabled: false)
    case ("led", _):
        guard let state = LEDState(rawValue: argument) else { print(usage); exit(2) }
        try hw.setLED(state)
    case ("limit", "off"):
        try hw.setChargeLimit(nil)
    case ("limit", _):
        guard let limit = Int(argument) else { print(usage); exit(2) }
        try hw.setChargeLimit(limit)
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

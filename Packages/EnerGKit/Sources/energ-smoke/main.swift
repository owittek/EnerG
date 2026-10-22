import Foundation
import EnerGCore
import EnerGMac

let usage = "usage: energ-smoke status | get-limit | adapter on|off | led system|off|green|orange | limit <50-100>|off"
let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? ""
let argument = args.count > 1 ? args[1] : ""

do {
    let hw = try MacHardware(healsAdapter: false)
    switch (command, argument) {
    case ("status", _):
        print(try hw.snapshot())
    case ("get-limit", _):
        let (limit, enabled) = try hw.nativeLimitState()
        print("\(enabled ? "\(limit)" : "off") CHLT=\(hw.smcLimit().map(String.init) ?? "off")")
    case ("adapter", "on"):
        try hw.setAdapter(enabled: true)
    case ("adapter", "off"):
        try hw.setAdapter(enabled: false)
    case ("led", _):
        guard let state = LEDState(rawValue: argument) else { print(usage); exit(2) }
        try hw.setLED(state)
    case ("limit", "off"):
        print(try hw.setChargeLimit(nil).map(String.init) ?? "off")
    case ("limit", _):
        guard let limit = Int(argument), (50...100).contains(limit) else { print(usage); exit(2) }
        print(try hw.setChargeLimit(limit).map(String.init) ?? "off")   // the limit now in effect
    default:
        print(usage)
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

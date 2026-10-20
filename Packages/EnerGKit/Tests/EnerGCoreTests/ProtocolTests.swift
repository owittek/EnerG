import Foundation
import Testing
@testable import EnerGCore

struct ProtocolTests {
    @Test(arguments: [
        Request.getStatus, .setLimit(85), .discharge(to: 50), .cancelDischarge, .topUp, .cancelTopUp,
        .setLEDMode(.blink), .setAutoDischarge(false), .setPaused(true), .release,
    ])
    func requestRoundTrips(_ request: Request) throws {
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(Request.self, from: data) == request)
    }

    @Test func statusRoundTrips() throws {
        let status = Status(
            state: .discharging,
            settings: Settings(chargeLimit: 90, autoDischarge: false, ledMode: .off, paused: false),
            snapshot: BatterySnapshot(percent: 93, isCharging: false, adapterConnected: false,
                                      adapterWatts: 96, batteryWatts: -12.5, systemWatts: nil),
            dischargeTarget: 90,
            toppingUp: true,
            warnings: [.weakAdapter, .unavailable(.led), .batteryUnreadable]
        )
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(Status.self, from: data) == status)
    }

    @Test func defaultSettings() {
        #expect(Settings() == Settings(chargeLimit: 80, autoDischarge: true, ledMode: .auto, paused: false))
        #expect(Settings.allowedLimits == [80, 85, 90, 95, 100])
    }
}

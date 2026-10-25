import Foundation
import Testing
@testable import EnerGCore

struct ProtocolTests {
    @Test(arguments: [
        Request.getStatus, .setLimit(85), .topUp, .cancelTopUp, .setLEDMode(.off), .setPaused(true), .release,
    ])
    func requestRoundTrips(_ request: Request) throws {
        let data = try JSONEncoder().encode(request)
        #expect(try JSONDecoder().decode(Request.self, from: data) == request)
    }

    @Test func snapshotWithoutPlugSensedDecodes() throws {
        let json = #"{"percent":81,"isCharging":false,"adapterConnected":true,"adapterWatts":60,"batteryWatts":-5.5,"systemWatts":11}"#
        let snapshot = try JSONDecoder().decode(BatterySnapshot.self, from: Data(json.utf8))
        #expect(snapshot == BatterySnapshot(percent: 81, isCharging: false, adapterConnected: true,
                                            adapterWatts: 60, batteryWatts: -5.5, systemWatts: 11))
        #expect(snapshot.plugSensed)
    }

    @Test func snapshotWithoutFirmwareLimitDecodes() throws {
        let json = #"{"percent":81,"isCharging":false,"adapterConnected":true,"batteryWatts":-5.5,"plugSensed":true}"#
        let snapshot = try JSONDecoder().decode(BatterySnapshot.self, from: Data(json.utf8))
        #expect(snapshot.firmwareLimit == nil)
    }

    @Test func snapshotFirmwareLimitRoundTrips() throws {
        let snapshot = BatterySnapshot(percent: 62, isCharging: true, adapterConnected: true, adapterWatts: 70,
                                       batteryWatts: 40, systemWatts: 20, firmwareLimit: 60)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(BatterySnapshot.self, from: data) == snapshot)
    }

    @Test func statusRoundTrips() throws {
        let status = Status(
            state: .atLimit,
            settings: Settings(chargeLimit: 90, ledMode: .off, paused: false),
            snapshot: BatterySnapshot(percent: 93, isCharging: false, adapterConnected: false,
                                      adapterWatts: 96, batteryWatts: -12.5, systemWatts: nil),
            effectiveLimit: 80,
            toppingUp: true,
            warnings: [.lowLimitUnsupported, .unavailable(.led), .batteryUnreadable]
        )
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(Status.self, from: data) == status)
    }

    @Test func defaultSettings() {
        #expect(Settings() == Settings(chargeLimit: 80, ledMode: .auto, paused: false))
        #expect(Settings.allowedLimits == [50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100])
    }
}

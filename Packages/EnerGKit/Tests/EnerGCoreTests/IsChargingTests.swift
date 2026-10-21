import Testing
@testable import EnerGCore

struct IsChargingTests {
    private func charging(_ chlt: [UInt8]?, percent: Int = 50, registry: Bool = false, plugged: Bool = true) -> Bool {
        BatterySnapshot.isCharging(chlt: chlt, percent: percent, adapterConnected: plugged,
                                   registryIsCharging: registry)
    }

    // The CHLT status byte is live; IsCharging lags up to a minute behind it.
    @Test func limitOnFollowsTheFirmwareStatus() {
        #expect(charging([60, 0x05, 0x00], registry: false))
        #expect(!charging([60, 0x05, 0x03], registry: true))
        #expect(!charging([60, 0x05, 0x05], registry: true))
    }

    // Straight after a limit write the status byte reads 00 for about a second before it settles on 05.
    @Test func atOrAboveTheLimitIsNeverCharging() {
        #expect(!charging([60, 0x05, 0x00], percent: 60))
        #expect(!charging([60, 0x05, 0x00], percent: 61))
        #expect(charging([60, 0x05, 0x00], percent: 59))
    }

    @Test func fallsBackToTheRegistry() {
        #expect(charging(nil, registry: true))
        #expect(charging([0, 0x05, 0x00], registry: true))      // limit off: 00 doesn't mean charging
        #expect(!charging([0, 0x05, 0x00], registry: false))
        #expect(charging([60, 0x05, 0x07], registry: true))     // unknown status
        #expect(!charging([60, 0x05, 0x00], registry: false, plugged: false))
        #expect(!charging([60, 0x05], registry: false))
    }
}

import Foundation
import Testing
@testable import EnerGCore

struct SettingsStoreTests {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "energ-tests-\(UUID().uuidString)/nested/settings.json")

    @Test func missingFileLoadsDefaults() {
        #expect(SettingsStore(url: url).load() == Settings())
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = SettingsStore(url: url)
        let settings = Settings(chargeLimit: 95, autoDischarge: false, ledMode: .blink, paused: true)
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func disallowedChargeLimitLoadsDefaultLimit() throws {
        let store = SettingsStore(url: url)
        try store.save(Settings(chargeLimit: 87, autoDischarge: false, ledMode: .off, paused: true))
        #expect(store.load() == Settings(chargeLimit: 80, autoDischarge: false, ledMode: .off, paused: true))
    }

    @Test func corruptFileLoadsDefaults() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(SettingsStore(url: url).load() == Settings())
    }
}

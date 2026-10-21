import Foundation
import Testing
@testable import EnerGCore

/// A class so `deinit` can remove each test's temp directory.
final class SettingsStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "energ-tests-\(UUID().uuidString)")
    var url: URL { root.appending(path: "nested/settings.json") }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func missingFileLoadsDefaults() {
        #expect(SettingsStore(url: url).load() == Settings())
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = SettingsStore(url: url)
        let settings = Settings(chargeLimit: 95, ledMode: .off, paused: true)
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func disallowedChargeLimitLoadsDefaultLimit() throws {
        let store = SettingsStore(url: url)
        try store.save(Settings(chargeLimit: 87, ledMode: .off, paused: true))
        #expect(store.load() == Settings(chargeLimit: 80, ledMode: .off, paused: true))
    }

    @Test func corruptFileLoadsDefaults() throws {
        try write("not json")
        #expect(SettingsStore(url: url).load() == Settings())
    }

    @Test func missingFieldDefaultsOnlyThatField() throws {
        try write(#"{"chargeLimit":90,"paused":true}"#)
        #expect(SettingsStore(url: url).load() == Settings(chargeLimit: 90, ledMode: .auto, paused: true))
    }

    @Test func invalidFieldDefaultsOnlyThatField() throws {
        try write(#"{"chargeLimit":90,"ledMode":"rainbow","paused":true}"#)
        #expect(SettingsStore(url: url).load() == Settings(chargeLimit: 90, ledMode: .auto, paused: true))
    }

    // A settings file from a build with Discharge: the old key is ignored, Blink falls back to Auto.
    @Test func settingsFromDischargeBuildLoad() throws {
        try write(#"{"chargeLimit":90,"autoDischarge":false,"ledMode":"blink","paused":true}"#)
        #expect(SettingsStore(url: url).load() == Settings(chargeLimit: 90, ledMode: .auto, paused: true))
    }
}

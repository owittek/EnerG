import Foundation

/// JSON persistence for `Settings`. A missing or unreadable file yields defaults;
/// a Charge Limit outside `Settings.allowedLimits` falls back to the default.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> Settings {
        guard let data = try? Data(contentsOf: url),
              var settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        if !Settings.allowedLimits.contains(settings.chargeLimit) { settings.chargeLimit = Settings().chargeLimit }
        return settings
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }
}

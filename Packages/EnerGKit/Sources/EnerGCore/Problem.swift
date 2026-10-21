/// Something wrong that the popover shows as its one problem notice: a click that failed, a dropped change, or the
/// connection to energd. Copy lives here, not in the app, so it is unit-tested.
public enum Problem: Equatable, Sendable {
    /// Registering the helper failed (not the normal wait for approval in Login Items).
    case installFailed
    /// `release` failed during uninstall, so the helper is still installed.
    case releaseFailed
    case uninstallFailed
    /// Turning Launch at Login on or off failed.
    case launchAtLoginFailed
    /// A change was retried for `Reconciler.retryWindow` without reaching energd, then dropped.
    case changeNotApplied
    /// A change is being retried.
    case waitingForHelper
    /// Polls can't reach energd.
    case helperUnreachable

    /// The one problem to show: a dropped change or failed release first (they are about the helper), then the
    /// connection, then any other failed click.
    public static func shown(failure: Problem?, connection: Problem?) -> Problem? {
        if let failure, failure == .changeNotApplied || failure == .releaseFailed { return failure }
        return connection ?? failure
    }

    public var message: String {
        switch self {
        case .installFailed: "Couldn't install the helper."
        case .releaseFailed: "Couldn't hand charging back to macOS, so the helper is still installed."
        case .uninstallFailed: "Couldn't uninstall the helper."
        case .launchAtLoginFailed: "Couldn't change Launch at Login."
        case .changeNotApplied: "Helper not reachable. Your change wasn't applied."
        case .waitingForHelper: "Waiting for helper…"
        case .helperUnreachable: "Helper not reachable."
        }
    }

    /// The button the notice offers, if any.
    public var action: ProblemAction? {
        switch self {
        case .releaseFailed: .uninstallAnyway
        case .launchAtLoginFailed: .openLoginItems
        case .installFailed, .uninstallFailed, .changeNotApplied, .waitingForHelper, .helperUnreachable: nil
        }
    }

    /// Still in progress: shown with a spinner instead of an error icon.
    public var isPending: Bool { self == .waitingForHelper }
}

/// What a problem notice's button does.
public enum ProblemAction: Equatable, Sendable {
    /// Unregister the helper without `release`.
    case uninstallAnyway
    /// Open System Settings → General → Login Items.
    case openLoginItems

    public var title: String {
        switch self {
        case .uninstallAnyway: "Uninstall Anyway"
        case .openLoginItems: "Open Login Items"
        }
    }
}

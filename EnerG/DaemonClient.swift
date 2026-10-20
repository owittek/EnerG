import XPC
import EnerGCore

/// Sends one Request to energd. A fresh session per call: calls are rare
/// (2 s polling while the popover is open), and this avoids stale-session handling.
struct DaemonClient: Sendable {
    func send(_ request: Request) async throws -> Status {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let session = try XPCSession(machService: DaemonID.machService, options: .privileged,
                                             requirement: .isFromSameTeam())
                try session.send(request) { (result: Result<Status, any Error>) in
                    session.cancel(reason: "done")
                    continuation.resume(with: result)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

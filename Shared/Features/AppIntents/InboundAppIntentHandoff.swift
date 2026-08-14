import Foundation

/// Makes the write → open → unique-payload-clear ordering explicit and testable.
/// In particular, a failed `UIApplication.open` may clear only the uniquely
/// identified envelope it wrote — never a newer invocation's replacement.
@MainActor
enum InboundAppIntentHandoff {
    enum Error: LocalizedError, Equatable {
        case invalidRoute
        case failedToOpenRoute

        var errorDescription: String? {
            switch self {
            case .invalidRoute:
                "Manifold could not construct its inbound handoff route."
            case .failedToOpenRoute:
                "Manifold could not open its inbound handoff route."
            }
        }
    }

    static func writeAndOpen(
        write: () throws -> UUID,
        discardWrittenPayload: (UUID) -> Void,
        open: () async -> Bool
    ) async throws {
        let handoffID = try write()
        guard await open() else {
            discardWrittenPayload(handoffID)
            throw Error.failedToOpenRoute
        }
    }
}

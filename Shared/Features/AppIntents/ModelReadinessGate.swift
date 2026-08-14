import Foundation
import ManifoldInference

/// Readiness gate shared by the background App Intent handler and its focused
/// tests. It observes the production readiness stream rather than guessing a
/// delay: a background prompt must wait through `.idle`/`.loading`, and a
/// stream ending before `.ready` is a visible failure rather than inference on
/// an unloaded model.
enum AppIntentModelReadinessGate {
    enum Error: LocalizedError, Equatable {
        case streamEndedBeforeModelReady

        var errorDescription: String? {
            "Manifold stopped observing model readiness before a model became available."
        }
    }

    static func waitUntilReady(
        _ readinessUpdates: AsyncStream<ModelLoadReadinessState>
    ) async throws {
        for await readiness in readinessUpdates {
            try Task.checkCancellation()
            guard readiness == .ready else { continue }
            return
        }
        throw Error.streamEndedBeforeModelReady
    }

    /// Runs `work` only after the readiness gate completes. Kept as a small
    /// generic seam so the background handler's ordering is testable without
    /// substituting a persistence or inference runtime.
    static func executeWhenReady<Value: Sendable>(
        waitForReadiness: @Sendable () async throws -> Void,
        work: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await waitForReadiness()
        return try await work()
    }
}

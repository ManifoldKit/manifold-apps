import Foundation
import ManifoldInference

/// Readiness gate shared by the background App Intent handler and its focused
/// tests. It delegates to `InferenceService`'s production readiness helper:
/// `.idle` fails immediately, `.loading` has its bounded timeout, and task
/// cancellation is rethrown rather than silently becoming inference on an
/// unloaded model.
enum AppIntentModelReadinessGate {
    enum Error: LocalizedError, Equatable {
        case modelUnavailable

        var errorDescription: String? {
            "Manifold did not have a ready model for the background request."
        }
    }

    static func waitUntilReady(
        _ readinessUpdates: AsyncStream<ModelLoadReadinessState>,
        maxPollCount: Int = 300,
        pollIntervalNanoseconds: UInt64 = 50_000_000
    ) async throws {
        try Task.checkCancellation()
        let isReady = await InferenceService.waitUntilModelReady(
            readinessUpdates: readinessUpdates,
            maxPollCount: maxPollCount,
            pollIntervalNanoseconds: pollIntervalNanoseconds
        )
        try Task.checkCancellation()
        guard isReady else { throw Error.modelUnavailable }
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

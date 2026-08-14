import Foundation
import ManifoldInference

/// Single-slot buffer for inbound payloads that arrive before the app is
/// ready to handle them.
///
/// Derived from ManifoldKit's own
/// `Example/Advanced/Concurrency/PendingPayloadBuffer.swift` and extended
/// with the published InferenceService model-readiness stream.
///
/// This actor holds the latest payload until the composition root observes a
/// ready model and hands it to `ChatViewModel.ingest(_:)`.
/// If a second payload arrives before the first is drained, the **later**
/// one wins — intentionally not queued, because a user firing two intents
/// in quick succession almost certainly meant the most recent one.
actor PendingPayloadBuffer {

    enum DeliveryState: Equatable {
        case idle
        case waitingForModel
        case delivering
        case delivered
        case readinessStreamEnded
    }

    private var pending: InboundPayload?
    private var pendingGeneration: UUID?
    private var deliveryState: DeliveryState = .idle

    /// Stores `payload`, replacing any previously-buffered payload, and
    /// returns its generation token. A delivery task may consume only the
    /// exact generation it observed: this prevents an older ready task from
    /// draining a later warm-route payload between store and cancellation.
    @discardableResult
    func store(_ payload: InboundPayload) -> UUID {
        let generation = UUID()
        pending = payload
        pendingGeneration = generation
        return generation
    }

    /// Returns the buffered payload without consuming it, or `nil` if the
    /// buffer is empty.
    func peek() -> InboundPayload? {
        pending
    }

    /// Removes and returns the buffered payload, or `nil` if the buffer is
    /// empty.
    func drain() -> InboundPayload? {
        let value = pending
        pending = nil
        pendingGeneration = nil
        return value
    }

    func currentGeneration() -> UUID? {
        pendingGeneration
    }

    /// Holds the payload through `.idle` and `.loading` lifecycle states and
    /// consumes it only after the published InferenceService readiness stream
    /// reaches `.ready`. A stream that ends without readiness leaves the
    /// payload buffered for a later installation attempt.
    func deliverWhenModelReady(
        generation: UUID,
        readinessUpdates: AsyncStream<ModelLoadReadinessState>,
        deliver: @MainActor @Sendable (InboundPayload) async -> Void
    ) async {
        guard !Task.isCancelled, pendingGeneration == generation else { return }
        deliveryState = .waitingForModel

        for await readiness in readinessUpdates {
            guard !Task.isCancelled else { return }
            guard readiness == .ready else { continue }
            // A later store changes `pendingGeneration` before its caller can
            // cancel this task. Do the token check inside the actor directly
            // before drain, so the predecessor can never consume the newer
            // single-slot payload.
            guard pendingGeneration == generation else { return }
            guard let payload = drain() else { return }
            deliveryState = .delivering
            await deliver(payload)
            deliveryState = .delivered
            return
        }

        guard pendingGeneration == generation else { return }
        deliveryState = .readinessStreamEnded
    }

    func currentDeliveryState() -> DeliveryState {
        deliveryState
    }
}

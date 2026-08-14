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
        case deliveryUnacknowledged
        case readinessStreamEnded
    }

    private var pending: InboundPayload?
    private var pendingGeneration: UUID?
    private var deliveryClaimGeneration: UUID?
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

    /// Holds the payload through `.idle` and `.loading` lifecycle states and
    /// asks its delivery closure to ingest it only after the published
    /// InferenceService readiness stream reaches `.ready`. The exact payload
    /// remains buffered until that closure acknowledges ingestion, so a
    /// replacement task cancelled between readiness and `ChatViewModel.ingest`
    /// cannot lose the cold-start envelope. A stream that ends without
    /// readiness also leaves the payload buffered for a later installation.
    func deliverWhenModelReady(
        generation: UUID,
        readinessUpdates: AsyncStream<ModelLoadReadinessState>,
        deliver: @MainActor @Sendable (InboundPayload) async -> Bool
    ) async {
        guard !Task.isCancelled, pendingGeneration == generation else { return }
        // Awaiting the acknowledgement closure re-enters this actor. Claim
        // the generation first so a duplicate install cannot hand the same
        // pending payload to a second closure while the first is suspended.
        guard deliveryClaimGeneration != generation else { return }
        deliveryClaimGeneration = generation
        defer {
            if deliveryClaimGeneration == generation {
                deliveryClaimGeneration = nil
            }
        }
        deliveryState = .waitingForModel

        for await readiness in readinessUpdates {
            guard !Task.isCancelled else { return }
            guard readiness == .ready else { continue }
            // A later store changes `pendingGeneration` before its caller can
            // cancel this task. Check inside the actor before handing the
            // payload out, so a predecessor can never deliver a replacement.
            guard pendingGeneration == generation else { return }
            guard let payload = pending else { return }
            deliveryState = .delivering
            let didIngest = await deliver(payload)
            guard didIngest else {
                // In particular, a task canceled after `.ready` but before
                // the closure acknowledges ingestion leaves the payload for
                // the replacement installation task.
                if pendingGeneration == generation {
                    deliveryState = .deliveryUnacknowledged
                }
                return
            }
            // The closure may suspend while a newer warm route stores a
            // replacement. An acknowledged predecessor must not drain it.
            guard pendingGeneration == generation else { return }
            _ = drain()
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

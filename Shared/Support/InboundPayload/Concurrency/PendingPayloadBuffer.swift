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
    private var deliveryState: DeliveryState = .idle

    /// Stores `payload`, replacing any previously-buffered payload.
    func store(_ payload: InboundPayload) {
        pending = payload
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
        return value
    }

    /// Holds the payload through `.idle` and `.loading` lifecycle states and
    /// consumes it only after the published InferenceService readiness stream
    /// reaches `.ready`. A stream that ends without readiness leaves the
    /// payload buffered for a later installation attempt.
    func deliverWhenModelReady(
        readinessUpdates: AsyncStream<ModelLoadReadinessState>,
        deliver: @MainActor @Sendable (InboundPayload) async -> Void
    ) async {
        guard pending != nil else { return }
        deliveryState = .waitingForModel

        for await readiness in readinessUpdates {
            guard !Task.isCancelled else { return }
            guard readiness == .ready else { continue }
            // `AppIntentsFeature.install(into:)` can replace an older
            // delivery task when a newer single-slot payload arrives. Check
            // again immediately before consuming so a cancelled predecessor
            // cannot drain the replacement payload.
            guard !Task.isCancelled else { return }
            guard let payload = drain() else { return }
            deliveryState = .delivering
            await deliver(payload)
            deliveryState = .delivered
            return
        }

        deliveryState = .readinessStreamEnded
    }

    func currentDeliveryState() -> DeliveryState {
        deliveryState
    }
}

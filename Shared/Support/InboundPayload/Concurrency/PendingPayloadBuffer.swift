import Foundation
import ManifoldInference

/// Single-slot buffer for inbound payloads that arrive before the app is
/// ready to handle them.
///
/// Ported near-verbatim from ManifoldKit's own
/// `Example/Advanced/Concurrency/PendingPayloadBuffer.swift` ahead of the
/// AppIntents/Extensions feature work that will actually produce payloads
/// for it to hold — not yet wired into `AppEnvironment`/`RootView` in this
/// scaffold.
///
/// This actor holds the latest payload until a post-mount hook drains it.
/// If a second payload arrives before the first is drained, the **later**
/// one wins — intentionally not queued, because a user firing two intents
/// in quick succession almost certainly meant the most recent one.
actor PendingPayloadBuffer {

    private var pending: InboundPayload?

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
}

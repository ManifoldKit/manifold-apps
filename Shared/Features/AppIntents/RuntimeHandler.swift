import Foundation
import ManifoldInference
import ManifoldAppIntents
import AppIntents

/// Adapts the host app's `InferenceService` to `AskManifoldHandler`.
///
/// Ported from ManifoldKit's own
/// `Example/Advanced/Intents/RuntimeHandler.swift`. `AskManifoldIntent`
/// calls back through this actor so `ManifoldAppIntents` stays decoupled
/// from `ManifoldRuntime` / SwiftData — that dep line would otherwise drag
/// persistence plumbing into every consumer of `ManifoldAppIntents`.
///
/// The implementation fires a single-shot `generate` call (no session
/// persistence) because the intent surface is stateless from the system's
/// perspective: Siri hands in a prompt and expects a reply string. This
/// deliberately does NOT go through `ConversationRuntime` / the persisted
/// session list — a Siri-driven background query shouldn't silently create
/// or mutate a chat session the user never sees.
@available(iOS 18, macOS 15, *)
actor RuntimeHandler: AskManifoldHandler {

    private let inferenceService: InferenceService

    init(inferenceService: InferenceService) {
        self.inferenceService = inferenceService
    }

    func ask(_ prompt: String) async throws -> String {
        // `InferenceService` is `@MainActor`-isolated; `generate(messages:)`
        // returns a `GenerationStream` whose `events` is a Sendable
        // AsyncSequence. Hop to the main actor to call `generate`, then
        // consume the stream off-actor.
        let service = inferenceService
        let stream = try await MainActor.run {
            try service.generate(messages: [(role: "user", content: prompt)])
        }
        var reply = ""
        for try await event in stream.events {
            if case .token(let chunk) = event {
                reply += chunk
            }
        }
        return reply
    }

    func displayName() async -> String {
        "Manifold"
    }
}

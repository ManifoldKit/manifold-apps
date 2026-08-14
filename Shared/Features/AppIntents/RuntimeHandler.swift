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

    private enum Error: LocalizedError {
        case modelNoLongerReady

        var errorDescription: String? {
            switch self {
            case .modelNoLongerReady:
                "Manifold's model became unavailable before the request could start."
            }
        }
    }

    private let waitForReadiness: @Sendable () async throws -> Void
    private let generateReply: @Sendable (String) async throws -> String

    init(inferenceService: InferenceService) {
        self.waitForReadiness = {
            let updates = await MainActor.run {
                inferenceService.modelLoadReadinessUpdates()
            }
            try await AppIntentModelReadinessGate.waitUntilReady(updates)
        }
        self.generateReply = { prompt in
            // A model can unload after the readiness stream emitted `.ready`.
            // Re-check in the same MainActor hop as `generate` so the handler
            // never starts inference against an unloaded service.
            let stream = try await MainActor.run {
                guard inferenceService.modelLoadReadinessState == .ready else {
                    throw Error.modelNoLongerReady
                }
                return try inferenceService.generate(messages: [(role: "user", content: prompt)])
            }
            var reply = ""
            for try await event in stream.events {
                if case .token(let chunk) = event {
                    reply += chunk
                }
            }
            return reply
        }
    }

    /// Dependency-injected seam for readiness sequencing coverage. The app
    /// initializer above remains the only production construction path.
    init(
        waitForReadiness: @escaping @Sendable () async throws -> Void,
        generateReply: @escaping @Sendable (String) async throws -> String
    ) {
        self.waitForReadiness = waitForReadiness
        self.generateReply = generateReply
    }

    func ask(_ prompt: String) async throws -> String {
        try await AppIntentModelReadinessGate.executeWhenReady(
            waitForReadiness: waitForReadiness,
            work: { try await self.generateReply(prompt) }
        )
    }

    func displayName() async -> String {
        "Manifold"
    }

}

import AppIntents
import Foundation
import ManifoldInference
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)

/// App Intent that routes a prompt from Spotlight, Siri, or Shortcuts into a
/// fresh chat session inside the host app.
///
/// Ported from ManifoldKit's own
/// `Example/Advanced/Intents/AskManifoldDemoIntent.swift` — renamed to drop
/// "Demo" branding (this app is a real consumer app, not the SDK's demo).
///
/// ## How it works
///
/// 1. The intent writes a JSON-encoded ``InboundPayloadEnvelope`` into the
///    shared App Group `UserDefaults` (``ManifoldAppGroup/identifier``, key
///    ``ManifoldAppGroup/inboundKey``).
/// 2. It opens `manifold://ingest`. `RootView.onOpenURL` validates that
///    route and drains the envelope even when the app's scene is already
///    active. The generated iOS Info.plist registers the `manifold` scheme.
/// 3. On cold launch, `AppEnvironment.bootstrap(...)` stages the envelope;
///    `AppIntentsFeature.install(into:)` drains it only after the real
///    InferenceService publishes model readiness.
public struct AskManifoldAppIntent: AppIntent {

    public static let title: LocalizedStringResource = "Ask Manifold"

    public static let description = IntentDescription(
        "Sends a prompt to Manifold and opens the app with a fresh chat session.",
        categoryName: "Chat"
    )

    /// Foregrounds (or cold-launches) the host app so the user lands in the
    /// chat session the prompt seeded.
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "Prompt", description: "What would you like to ask Manifold?")
    public var prompt: String

    public init() {}

    public init(prompt: String) {
        self.prompt = prompt
    }

    @MainActor
    public func perform() async throws -> some IntentResult {
        // The envelope carries both the prompt and an attachments array so
        // a future richer entry point (Share / Action Extension) can
        // propagate `MessagePart` payloads end-to-end on the same code
        // path without a second App Group key. This intent only ever
        // populates the prompt.
        let envelope = InboundPayloadEnvelope(
            prompt: prompt,
            attachments: [],
            source: "appIntent"
        )
        do {
            #if canImport(UIKit)
            guard let route = InboundAppIntentRoute.url else {
                throw InboundAppIntentHandoff.Error.invalidRoute
            }
            try await InboundAppIntentHandoff.writeAndOpen(
                write: { try InboundAppIntentEnvelopeStore.write(envelope) },
                discardIfCurrent: InboundAppIntentEnvelopeStore.discardIfCurrent,
                open: { await UIApplication.shared.open(route, options: [:]) }
            )
            #else
            try InboundAppIntentEnvelopeStore.write(envelope)
            #endif
        } catch {
            Log.ui.error("AskManifoldAppIntent: failed to hand off inbound envelope: \(String(describing: error), privacy: .public)")
            throw error
        }

        return .result()
    }
}

#endif

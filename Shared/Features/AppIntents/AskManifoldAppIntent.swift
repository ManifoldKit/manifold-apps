import AppIntents
import Foundation
import ManifoldInference

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
/// 2. `openAppWhenRun` foregrounds (or cold-launches) the host app — no
///    custom URL scheme is used to trigger this, unlike core's demo. Core's
///    `manifolddemo://ingest` scheme exists purely to reach its
///    `.onOpenURL` handler synchronously; this app has no URL scheme
///    registered (that's a `project.yml` change, outside this feature's
///    ownership — see the PR description) and no `.onOpenURL` handler on
///    `Mobile/ManifoldApp.swift` / `Studio/ManifoldStudioApp.swift` (also
///    outside this feature's ownership). `openAppWhenRun` alone is enough
///    to guarantee the cold-launch case: `AppEnvironment.bootstrap(...)`
///    stages the envelope during startup, then
///    `AppIntentsFeature.install(into:)` drains it only after the real
///    InferenceService publishes model readiness.
/// 3. A **warm** relaunch (app already foregrounded when the intent fires
///    again) is NOT caught today. Catching that case needs a
///    scenePhase/`.onOpenURL` hook in the app-entry files above; flagged as
///    a known gap rather than silently dropped.
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
            try InboundAppIntentEnvelopeStore.write(envelope)
        } catch {
            Log.ui.error("AskManifoldAppIntent: failed to persist inbound envelope: \(String(describing: error), privacy: .public)")
            throw error
        }

        return .result()
    }
}

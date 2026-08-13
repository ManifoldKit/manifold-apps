import SwiftUI
import ManifoldInference
import ManifoldAppIntents

/// AppIntent ↔ ToolDefinition bridge + inbound-payload handoff
/// (manifold-apps W2 P5).
///
/// Ports ManifoldKit's own `Example/Advanced` AppIntents surface:
/// `AskManifoldAppIntent`/`ManifoldShortcuts` (Siri/Spotlight entry points),
/// `RuntimeHandler` (wires the library's `AskManifoldIntent` to the host's
/// `InferenceService`), and `AppIntentToolsView`/`SetReminderIntent` (the
/// AppIntent → chat-tool bridge demo).
///
/// The feature receives `AppEnvironment.toolRegistry`, the same registry
/// instance used to construct `InferenceService`. Registering an AppIntent
/// here therefore changes the definitions advertised to subsequent chat
/// turns instead of mutating a UI-only registry.
enum AppIntentsFeature: AppFeature {
    static let id = "appintents"
    static let title = "App Intents"
    static let systemImage = "bolt.badge.a"

    /// Single-slot buffer for an inbound payload that arrives before the
    /// runtime is ready to ingest it.
    ///
    /// Ported (in `Shared/Support/InboundPayload/Concurrency/`) ahead of
    /// this feature so its shape was settled before this worker landed;
    /// this is the first real producer/consumer pair to exercise it.
    /// `install(into:)` below is currently both the sole writer (seeded
    /// from the App Group envelope on cold launch) and the sole reader
    /// (drained into `env.viewModel.ingest(_:)` on the very next line) — a
    /// future `.onOpenURL` / scenePhase hook on `Mobile/ManifoldApp.swift`
    /// / `Studio/ManifoldStudioApp.swift` (outside this feature's
    /// ownership) can call `.store(_:)` on this same instance to cover the
    /// warm-relaunch case documented on `AskManifoldAppIntent`.
    static let pendingPayloadBuffer = PendingPayloadBuffer()

    static func install(into env: AppEnvironment) {
        Task { @MainActor in
            if let payload = Self.readInboundEnvelope() {
                await pendingPayloadBuffer.store(payload)
            }
            if let payload = await pendingPayloadBuffer.drain() {
                await env.viewModel.ingest(payload)
            }

            if #available(iOS 18, macOS 15, *) {
                await ManifoldIntentConfiguration.shared.configure(
                    handler: RuntimeHandler(inferenceService: env.bootstrap.inferenceService)
                )
            }
        }
    }

    static func makeView(env: AppEnvironment) -> AnyView {
        if #available(iOS 26, macOS 26, *) {
            return AnyView(
                AppIntentToolsView(toolRegistry: env.toolRegistry)
                    .accessibilityIdentifier("appintents-feature-view")
            )
        }
        return AnyView(
            AppIntentsUnavailableView()
                .accessibilityIdentifier("appintents-feature-view")
        )
    }

    // MARK: - Inbound payload handoff

    /// Reads and clears the JSON envelope `AskManifoldAppIntent` may have
    /// written to the shared App Group defaults before this launch,
    /// decoding it into the `InboundPayload` shape
    /// `ChatViewModel.ingest(_:)` expects.
    ///
    /// Ported from ManifoldKit's own `ManifoldDemoApp.handleOpenURL(_:)`,
    /// minus the `.onOpenURL`/URL-scheme trigger this app doesn't have —
    /// see `AskManifoldAppIntent`'s doc comment.
    private static func readInboundEnvelope() -> InboundPayload? {
        guard let defaults = UserDefaults(suiteName: ManifoldAppGroup.identifier),
              let data = defaults.data(forKey: ManifoldAppGroup.inboundKey) else {
            return nil
        }
        // Clear immediately so a decode failure or a crash mid-ingest
        // doesn't replay the same envelope on the next launch.
        defaults.removeObject(forKey: ManifoldAppGroup.inboundKey)

        let envelope: InboundPayloadEnvelope
        do {
            envelope = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data)
        } catch {
            Log.ui.warning("AppIntentsFeature: failed to decode inbound envelope; discarding")
            return nil
        }

        return InboundPayload(
            prompt: envelope.prompt,
            attachments: envelope.attachments,
            source: decodeSource(envelope.source)
        )
    }

    private static func decodeSource(_ raw: String) -> InboundPayload.Source {
        switch raw {
        case "deepLink": return .deepLink
        case "shareExtension": return .shareExtension
        case "appIntent": return .appIntent
        default:
            Log.ui.warning("AppIntentsFeature: unknown inbound source '\(raw, privacy: .public)' — defaulting to .appIntent")
            return .appIntent
        }
    }
}

/// Shown by `AppIntentsFeature.makeView(env:)` when the OS is below the
/// iOS 26 / macOS 26 availability floor of `AppIntentToolExecutor`.
private struct AppIntentsUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("App Intents", systemImage: "bolt.badge.a")
        } description: {
            Text("The AppIntent → tool bridge requires iOS 26 or macOS 26.")
        }
    }
}

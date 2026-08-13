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
    /// Startup stores the App Group envelope here before bootstrap, and
    /// `install(into:)` drains it only after the service publishes `.ready`.
    /// A future `.onOpenURL` / scenePhase hook can store into this same actor
    /// to cover the warm-relaunch case documented on
    /// `AskManifoldAppIntent`.
    static let pendingPayloadBuffer = PendingPayloadBuffer()
    private static var deliveryTask: Task<Void, Never>?
    private(set) static var inboundHandoffStatus = "No inbound AppIntent payload staged."

    /// Startup-phase hook called as soon as the composition root has created
    /// its InferenceService. This intentionally precedes session restoration,
    /// model loading, and RootView construction: background AskManifoldIntent
    /// invocations do not open the app and cannot depend on a view appearing.
    static func configureBackgroundIntentHandler(inferenceService: InferenceService) async {
        if #available(iOS 18, macOS 15, *) {
            await ManifoldIntentConfiguration.shared.configure(
                handler: RuntimeHandler(inferenceService: inferenceService)
            )
        }
    }

    /// Consumes the App Group slot before the potentially long bootstrap. The
    /// decoded payload remains in the actor buffer until model readiness is
    /// published; malformed data is cleared and reported instead of replayed.
    static func stageInboundPayloadDuringStartup() async {
        InboundAppIntentEnvelopeStore.seedUITestEnvelopeIfRequested()
        switch InboundAppIntentEnvelopeStore.take() {
        case .empty:
            inboundHandoffStatus = "No inbound AppIntent payload staged."
        case .payload(let payload):
            await pendingPayloadBuffer.store(payload)
            inboundHandoffStatus = "Inbound AppIntent payload buffered until model readiness."
        case .malformed(let error):
            inboundHandoffStatus = "Malformed inbound AppIntent payload discarded."
            Log.ui.warning("AppIntentsFeature: malformed inbound envelope discarded: \(String(describing: error), privacy: .public)")
        case .appGroupUnavailable:
            inboundHandoffStatus = "App Group unavailable; inbound AppIntent handoff disabled."
            Log.ui.error("AppIntentsFeature: App Group '\(ManifoldAppGroup.identifier, privacy: .public)' unavailable")
        }
    }

    static func install(into env: AppEnvironment) {
        guard deliveryTask == nil else { return }
        let readinessUpdates = env.bootstrap.inferenceService.modelLoadReadinessUpdates()
        deliveryTask = Task { @MainActor in
            defer { deliveryTask = nil }
            await pendingPayloadBuffer.deliverWhenModelReady(
                readinessUpdates: readinessUpdates
            ) { payload in
                await env.viewModel.ingest(payload)
                inboundHandoffStatus = "Inbound AppIntent payload delivered after model readiness."
            }
        }
    }

    static func makeView(env: AppEnvironment) -> AnyView {
        if #available(iOS 26, macOS 26, *) {
            return AnyView(
                AppIntentToolsView(
                    toolRegistry: env.toolRegistry,
                    inferenceService: env.bootstrap.inferenceService,
                    inboundHandoffStatus: inboundHandoffStatus
                )
                    .accessibilityIdentifier("appintents-feature-view")
            )
        }
        return AnyView(
            AppIntentsUnavailableView()
                .accessibilityIdentifier("appintents-feature-view")
        )
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

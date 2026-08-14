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
    /// The app's `manifold://ingest` URL handler re-checks the App Group slot
    /// for every warm invocation.
    static let pendingPayloadBuffer = PendingPayloadBuffer()
    private static var deliveryTask: Task<Void, Never>?
    private static var deliveryTaskID: UUID?
    private(set) static var inboundHandoffStatus = "No inbound AppIntent payload staged."

    /// Startup-phase hook called as soon as the composition root has created
    /// its InferenceService. This intentionally precedes session restoration,
    /// model loading, and RootView construction: background AskManifoldIntent
    /// invocations do not open the app and cannot depend on a view appearing.
    static func configureBackgroundIntentHandler(inferenceService: InferenceService) async -> Bool {
        if #available(iOS 18, macOS 15, *) {
            await ManifoldIntentConfiguration.shared.configure(
                handler: RuntimeHandler(inferenceService: inferenceService)
            )
            return await ManifoldIntentConfiguration.shared.handler != nil
        }
        return false
    }

    /// Consumes the App Group slot before the potentially long bootstrap. The
    /// decoded payload remains in the actor buffer until model readiness is
    /// published; malformed data is cleared and reported instead of replayed.
    static func stageInboundPayloadDuringStartup() async {
        InboundAppIntentEnvelopeStore.seedUITestEnvelopeIfRequested()
        await stageInboundPayload(InboundAppIntentEnvelopeStore.take())
    }

    /// UI-test-only seed for the warm URL contract. It deliberately writes
    /// after bootstrap and does not stage the buffer, leaving RootView's
    /// `.onOpenURL` path as the only way to consume it.
    static func seedWarmInboundPayloadForUITestIfRequested() {
        guard let prompt = LaunchArguments.warmAppIntentPrompt else { return }
        do {
            try InboundAppIntentEnvelopeStore.write(
                InboundPayloadEnvelope(prompt: prompt, source: "appIntent")
            )
            inboundHandoffStatus = "Warm AppIntent UI-test envelope awaiting URL route."
        } catch {
            inboundHandoffStatus = "Warm AppIntent UI-test envelope could not be seeded."
            Log.ui.error("AppIntentsFeature: failed to seed warm UI-test envelope: \(String(describing: error), privacy: .public)")
        }
    }

    static func isInboundAppIntentURL(_ url: URL) -> Bool {
        InboundAppIntentRoute.isInboundURL(url)
    }

    /// Drains the App Group slot after the authoritative inbound URL event. A
    /// warm `openAppWhenRun` invocation does not repeat bootstrap, so this is
    /// the production handoff that gets its envelope into the already-installed
    /// readiness delivery loop.
    static func stageAndDeliverInboundPayloadAfterActivation(into env: AppEnvironment) async {
        guard await stageInboundPayload(InboundAppIntentEnvelopeStore.take()) else { return }
        install(into: env)
    }

    /// Kept separate from the store read so the state transition is directly
    /// testable with a synthetic App Group result. The URL handoff above
    /// always supplies the real store result.
    @discardableResult
    static func stageInboundPayload(_ result: InboundAppIntentEnvelopeStore.TakeResult) async -> Bool {
        switch result {
        case .empty:
            inboundHandoffStatus = "No inbound AppIntent payload staged."
            return false
        case .payload(let payload):
            await pendingPayloadBuffer.store(payload)
            inboundHandoffStatus = "Inbound AppIntent payload buffered until model readiness."
            return true
        case .malformed(let error):
            inboundHandoffStatus = "Malformed inbound AppIntent payload discarded."
            Log.ui.warning("AppIntentsFeature: malformed inbound envelope discarded: \(String(describing: error), privacy: .public)")
            return false
        case .appGroupUnavailable:
            inboundHandoffStatus = "App Group unavailable; inbound AppIntent handoff disabled."
            Log.ui.error("AppIntentsFeature: App Group '\(ManifoldAppGroup.identifier, privacy: .public)' unavailable")
            return false
        }
    }

    static func install(into env: AppEnvironment) {
        deliveryTask?.cancel()
        let taskID = UUID()
        deliveryTaskID = taskID
        let readinessUpdates = env.bootstrap.inferenceService.modelLoadReadinessUpdates()
        deliveryTask = Task { @MainActor in
            defer {
                if deliveryTaskID == taskID {
                    deliveryTask = nil
                    deliveryTaskID = nil
                }
            }
            guard let generation = await pendingPayloadBuffer.currentGeneration() else { return }
            await pendingPayloadBuffer.deliverWhenModelReady(
                generation: generation,
                readinessUpdates: readinessUpdates
            ) { payload in
                guard !Task.isCancelled else { return }
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
                    backgroundHandlerConfiguredAtStartup: env.backgroundIntentHandlerConfiguredAtStartup,
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

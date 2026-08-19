import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement

/// The single navigation shell for both iOS and macOS `Manifold` —
/// sessions + the platform feature registry in the sidebar, `ChatView` (or
/// a selected feature's view) in the detail column. Reads `AppEnvironment`
/// from the SwiftUI environment; owns no bootstrap state of its own.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    @State private var selectedFeatureID: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @State private var didInstallFeatures = false

    /// Satisfies `ChatView`'s required binding and drives the host-owned
    /// `ModelManagementSheet` presentation.
    @State private var showModelManagement = false
    /// The management surface owns search, download, and storage UI state.
    /// Keep it alive for RootView's lifetime so dismissing the sheet does not
    /// discard an in-flight download or a user's search state.
    @State private var modelManagementViewModel: ModelManagementViewModel

    init() {
        #if os(macOS)
        // UI tests exercise the real sheet and registry, but do not need a
        // background URLSession or its launch-time temporary-file hygiene.
        // Keeping that work out of the XCUITest bootstrap also prevents a
        // large host temp directory from delaying accessibility registration.
        let modelManagement = LaunchArguments.isUITesting
            ? ModelManagementViewModel.preview()
            : ModelManagementViewModel.live()
        #else
        let modelManagement = ModelManagementViewModel.live()
        #endif
        _modelManagementViewModel = State(initialValue: modelManagement)
    }

    private var featureTypes: [any AppFeature.Type] {
        #if os(iOS)
        MobileFeatureRegistry.all
        #else
        MacFeatureRegistry.all
        #endif
    }

    private var features: [FeatureEntry] {
        featureTypes.map(FeatureEntry.init)
    }

    private var selectedLoadIdentity: LoadSelectionIdentity {
        LoadSelectionIdentity(
            modelID: env.viewModel.selectedModel?.id,
            endpointID: env.viewModel.selectedEndpoint?.id
        )
    }

    var body: some View {
        // Establish Observation tracking for the pending queue so the
        // presentation binding below re-evaluates when a tool call arrives.
        let _ = env.toolApprovalGate.pending.count

        themedRoot
            .sheet(isPresented: $showModelManagement) {
                ModelManagementSheet(modelRegistry: env.viewModel.modelRegistry)
                    .environment(modelManagementViewModel)
                    .accessibilityIdentifier("model-management-sheet")
            }
            .sheet(isPresented: approvalSheetIsPresented) {
                if let call = env.toolApprovalGate.pending.first {
                    ToolApprovalSheet(call: call)
                        .environment(env.viewModel)
                } else {
                    Color.clear.frame(width: 1, height: 1)
                }
            }
            .overlay {
                // SwiftUI sheet timing is nondeterministic under XCUITest.
                // The deterministic tool-flow launch mounts the same real
                // approval view inline; its buttons still resolve the live
                // UIToolApprovalGate continuation used by the turn loop.
                if LaunchArguments.runsToolApprovalFlow,
                   let call = env.toolApprovalGate.pending.first {
                    ToolApprovalSheet(call: call)
                        .environment(env.viewModel)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 12)
                        .padding()
                }
            }
    }

    @ViewBuilder
    private var themedRoot: some View {
        if env.themePreset == .classic {
            rootContent
                .classicManifoldTheme()
        } else {
            rootContent
                .manifoldTheme(env.theme)
        }
    }

    private var rootContent: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            sidebar
        } detail: {
            detail
        }
        .environment(env.viewModel)
        .environment(env.sessionManager)
        .task {
            guard !didInstallFeatures else { return }
            didInstallFeatures = true
            for feature in featureTypes {
                feature.install(into: env)
            }
            // This is a test-only write guarded by `--uitesting`; it happens
            // after bootstrap and is intentionally not staged here. The warm
            // AppIntents UI regression must exercise the real `onOpenURL`
            // handoff below to consume it.
            AppIntentsFeature.seedWarmInboundPayloadForUITestIfRequested()
        }
        .onChange(of: selectedFeatureID) { oldValue, newValue in
            if newValue != nil { showCompactDetail() }

            guard oldValue == CloudFeature.id else { return }
            Task { await env.refreshAvailableEndpoints() }
        }
        .onChange(of: env.sessionManager.activeSession) { _, newSession in
            guard let newSession else { return }
            selectedFeatureID = "chat"
            showCompactDetail()

            guard env.viewModel.activeSession?.id != newSession.id else { return }
            Task { await env.viewModel.switchToSession(newSession) }
        }
        // ModelManagementSheet writes local choices directly to the shared
        // ModelRegistry; cloud selection writes selectedEndpoint. Observe one
        // combined identity rather than each property separately so the
        // synchronous endpoint/model exclusion in ChatViewModel settles before
        // dispatching exactly one latest-wins load intent.
        .onChange(of: selectedLoadIdentity) { _, selection in
            guard selection.hasSelection else { return }
            env.viewModel.dispatchSelectedLoad()
        }
        .onChange(of: modelManagementViewModel.completedDownloadCount) { _, _ in
            env.viewModel.refreshModels()
        }
        #if os(iOS)
        .onOpenURL { url in
            guard AppIntentsFeature.isInboundAppIntentURL(url) else { return }
            Task {
                await AppIntentsFeature.stageAndDeliverInboundPayloadAfterActivation(into: env)
            }
        }
        .onChange(of: horizontalSizeClass) { _, newSizeClass in
            guard newSizeClass != .compact else { return }
            columnVisibility = .automatic
        }
        #endif
        .onChange(of: env.viewModel.activeBackendName, initial: true) { _, _ in
            ToolsFeature.updateAdvertisement(in: env)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SessionListView()
            Divider()
            featureList
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: toolbarPlacement) {
                Button(action: createSession) {
                    Label("New Chat", systemImage: "plus")
                }
                .accessibilityLabel("New Chat")
                .accessibilityIdentifier("new-chat-button")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private var featureList: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            ScrollView {
                LazyVStack(spacing: 0) {
                    featureButton(
                        id: "chat",
                        title: "Chat",
                        systemImage: "bubble.left.and.bubble.right"
                    )

                    ForEach(features) { entry in
                        Divider()
                        featureButton(
                            id: entry.id,
                            title: entry.title,
                            systemImage: entry.systemImage
                        )
                    }
                }
            }
            .accessibilityIdentifier("feature-sidebar-list")
        } else {
            // Preserve NavigationSplitView's native regular-width selection
            // semantics. A button-based ScrollView is visually correct but
            // sits beneath the split view's detail hit-testing layer on iPad.
            List(selection: $selectedFeatureID) {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    .tag("chat")
                    .accessibilityIdentifier("feature-sidebar-row-chat")

                ForEach(features) { entry in
                    Label(entry.title, systemImage: entry.systemImage)
                        .tag(entry.id)
                        .accessibilityIdentifier("feature-sidebar-row-\(entry.id)")
                }
            }
            .accessibilityIdentifier("feature-sidebar-list")
        }
        #else
        // Keep the native selection affordance on macOS. On compact iPhones,
        // stacking this feature region as a second List below SessionListView
        // can swallow lower-row actions even when the row reports hittable.
        List(selection: $selectedFeatureID) {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
                .tag("chat")
                .accessibilityIdentifier("chat-sidebar-row")

            ForEach(features) { entry in
                Label(entry.title, systemImage: entry.systemImage)
                    .tag(entry.id)
            }
        }
        #endif
    }

    #if os(iOS)
    private func featureButton(id: String, title: String, systemImage: String) -> some View {
        Button(action: { selectFeature(id) }) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(selectedFeatureID == id ? Color.accentColor.opacity(0.14) : Color.clear)
        .accessibilityAddTraits(selectedFeatureID == id ? .isSelected : [])
        .accessibilityIdentifier("feature-sidebar-row-\(id)")
    }

    #endif

    private func selectFeature(_ id: String) {
        selectedFeatureID = id
        // `onChange` does not fire for a re-tap of the already-selected row,
        // but reasserting the compact detail column is still required when
        // the sidebar is currently presented over it.
        showCompactDetail()
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedFeatureID, let entry = features.first(where: { $0.id == selectedFeatureID }) {
            entry.type.makeView(env: env)
        } else {
            // Ordering matters: `.chatModelSwitcher` must be applied before
            // `.chatAPIConfiguration` — the latter constructs a fresh
            // `ChatView<Content>` that copies `modelSwitcherBuilder` from
            // the receiver, so calling it first would drop the switcher.
            ChatView(showModelManagement: $showModelManagement)
                .chatModelSwitcher { modelSwitcherContent }
                // APIConfigurationView and its nested editor both read the
                // store from EnvironmentValues. Attach it to the supplied
                // presentation content so ChatView's settings and API-key
                // recovery paths are wired explicitly at their point of use
                // (pinned by EndpointStoreUITests).
                .chatAPIConfiguration {
                    APIConfigurationView()
                        .environment(\.endpointStore, env.bootstrap.endpointStore)
                }
                // Keep one stable, app-owned accessibility container around
                // the conversation. iOS 27 can temporarily omit SwiftUI's
                // lazy message-bubble descendants from XCUI queries even
                // after they are visibly rendered; this value reflects the
                // runtime's atomic turn outcome instead of presentation
                // timing, and gives VoiceOver a concise conversation status.
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Chat conversation")
                .accessibilityValue(chatTurnAccessibilityValue)
                .accessibilityIdentifier("chat-conversation")
        }
    }

    private var chatTurnAccessibilityValue: String {
        switch env.viewModel.lastTurnState {
        case .idle:
            "Idle"
        case .generating:
            env.viewModel.isGenerating ? "Generating response" : "Idle"
        case .completed(let message):
            if message.sessionID == env.viewModel.activeSession?.id {
                "Response complete: \(message.content)"
            } else {
                "Idle"
            }
        case .failed:
            // TurnState does not carry a session ID for failures. ChatView's
            // error surface already exposes the active failure; never risk
            // announcing a prior session's error on the new conversation.
            "Idle"
        }
    }

    /// The `.chatModelSwitcher(_:)` content — `ChatView` (`ManifoldUI`)
    /// cannot import `ManifoldUIModelManagement`'s `ModelSwitcherView`
    /// itself (dependency direction), so the host supplies it here, same
    /// shape as core's own `Example/Advanced/DemoContentView.swift`.
    private var modelSwitcherContent: some View {
        ModelSwitcherView(
            rows: ModelSwitcher.rows(
                models: env.viewModel.availableModels,
                endpoints: env.viewModel.availableEndpoints,
                selectedModelID: env.viewModel.selectedModel?.id,
                selectedEndpointID: env.viewModel.selectedEndpoint?.id,
                physicalMemoryBytes: env.viewModel.physicalMemoryBytes,
                compatibility: env.viewModel.modelRegistry.compatibility(for:)
            ),
            onSelect: { entry in
                switch entry {
                case .model(let model):
                    env.viewModel.selectedModel = model
                case .endpoint(let endpoint):
                    env.viewModel.selectedEndpoint = endpoint
                }
            },
            onFixEndpoint: { _ in showModelManagement = true }
        )
    }

    private func showCompactDetail() {
        #if os(iOS)
        guard horizontalSizeClass == .compact else { return }
        columnVisibility = .detailOnly
        preferredCompactColumn = .detail
        #endif
    }

    private func createSession() {
        Task {
            do {
                try await env.sessionManager.createSession()
            } catch {
                env.viewModel.errorMessage = "Failed to create session: \(error.localizedDescription)"
            }
        }
    }

    private var toolbarPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .automatic
        #endif
    }

    private var approvalSheetIsPresented: Binding<Bool> {
        Binding(
            get: {
                !LaunchArguments.runsToolApprovalFlow
                    && !env.toolApprovalGate.pending.isEmpty
            },
            set: { isPresented in
                guard !isPresented, let call = env.toolApprovalGate.pending.first else { return }
                env.toolApprovalGate.resolve(
                    callId: call.id,
                    with: .denied(reason: "dismissed")
                )
            }
        )
    }
}

/// A single observable load-selection value for the host. `ChatViewModel`
/// keeps local models and cloud endpoints mutually exclusive, but selecting
/// either can synchronously clear the other. Coalescing them here prevents
/// those intermediate writes from issuing duplicate loads.
private struct LoadSelectionIdentity: Equatable {
    let modelID: UUID?
    let endpointID: UUID?

    init(modelID: UUID?, endpointID: UUID?) {
        self.modelID = modelID
        self.endpointID = endpointID
    }

    var hasSelection: Bool {
        modelID != nil || endpointID != nil
    }
}

/// Type-erased, `Identifiable` sidebar row wrapping an ``AppFeature``
/// conformer — `List` needs `Identifiable` value rows, and `AppFeature` is a
/// static-only protocol (no instances), so this adapts the metatype.
///
/// `id`/`title`/`systemImage` are captured into plain stored properties by
/// the `@MainActor` initializer rather than left as computed properties
/// reading `type.id` etc. on demand — `AppFeature`'s static members are
/// MainActor-isolated (the protocol itself is `@MainActor`), and
/// `Identifiable`'s `id` requirement is nonisolated, so a computed `id`
/// forwarding to `type.id` would make this type's `Identifiable`
/// conformance itself MainActor-isolated, which the plain protocol
/// requirement rejects.
private struct FeatureEntry: Identifiable {
    let type: any AppFeature.Type
    let id: String
    let title: String
    let systemImage: String

    @MainActor
    init(type: any AppFeature.Type) {
        self.type = type
        self.id = type.id
        self.title = type.title
        self.systemImage = type.systemImage
    }
}

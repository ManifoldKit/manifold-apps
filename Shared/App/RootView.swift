import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement

/// The single navigation shell for both `Manifold` and `ManifoldStudio` —
/// sessions + the platform feature registry in the sidebar, `ChatView` (or
/// a selected feature's view) in the detail column. Reads `AppEnvironment`
/// from the SwiftUI environment; owns no bootstrap state of its own.
struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var selectedFeatureID: String?
    @State private var didInstallFeatures = false

    /// Satisfies `ChatView`'s required binding. No `ModelManagementSheet` is
    /// wired to it yet in this scaffold — Cmd+Shift+M and the model
    /// switcher's "fix endpoint" affordance flip the flag, but nothing
    /// currently observes it. A follow-up feature PR wires the sheet.
    @State private var showModelManagement = false

    private var featureTypes: [any AppFeature.Type] {
        #if os(iOS)
        MobileFeatureRegistry.all
        #else
        StudioFeatureRegistry.all
        #endif
    }

    private var features: [FeatureEntry] {
        featureTypes.map(FeatureEntry.init)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .environment(env.viewModel)
        .environment(env.sessionManager)
        .manifoldTheme(env.theme)
        .task {
            guard !didInstallFeatures else { return }
            didInstallFeatures = true
            for feature in featureTypes {
                feature.install(into: env)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SessionListView()
            Divider()
            List(features, selection: $selectedFeatureID) { entry in
                Label(entry.title, systemImage: entry.systemImage)
            }
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

import Foundation
import SwiftData
import ManifoldKit
import ManifoldTools
#if os(macOS)
import ManifoldMLX
import ManifoldLlama
#endif

/// The composition root shared by `Manifold` (iOS) and `ManifoldStudio`
/// (macOS): owns the bootstrapped ManifoldKit stack (inference, persistence,
/// session management) plus the one piece of cross-feature UI state every
/// feature can read — the active theme.
///
/// `bootstrap` is exposed (not just `viewModel`/`sessionManager`) because
/// some ``ManifoldBootstrap`` members — `ragService`, `benchmarkCache`,
/// `samplerPresetStore`, `personaStore`, `endpointStore` — live on
/// `ManifoldBootstrap` itself, not on `ChatViewModel` (confirmed against
/// core's own source during tonight's W0 probe). Later features (Cloud,
/// Scenarios, …) reach them through `env.bootstrap`, not by growing this
/// type's own stored-property surface.
///
/// `toolRegistry` is likewise exposed directly rather than reachable only
/// through `viewModel.inferenceService` (which is `internal` and can't be
/// widened per AGENTS.md's "Service sharing" convention): at v0.75.0,
/// `InferenceService.toolRegistry` is a get-only computed property backed by
/// an init-time-only `ToolRegistry?`, and `ChatViewModel.toolApprovalGate`
/// is a `let` — so a feature confined to `Shared/Features/<Name>/` can never
/// register a dispatchable tool unless the registry (and the gate) are
/// constructed here, before `InferenceService`, and threaded through both
/// initializers. Mirrors core's own `Example/Advanced/ManifoldDemoApp.swift`
/// `init()`, which builds `registry`/`approvalGate` before the service for
/// exactly this reason (lines 88–93).
@MainActor
@Observable
final class AppEnvironment {
    let bootstrap: ManifoldBootstrap
    let viewModel: ChatViewModel
    let sessionManager: SessionManagerViewModel
    let toolRegistry: ToolRegistry
    let toolApprovalGate: UIToolApprovalGate
    let backgroundIntentHandlerConfiguredAtStartup: Bool
    var themePreset: ThemingPreset = .standard

    var theme: ManifoldTheme {
        themePreset.theme
    }

    private init(
        bootstrap: ManifoldBootstrap,
        viewModel: ChatViewModel,
        sessionManager: SessionManagerViewModel,
        toolRegistry: ToolRegistry,
        toolApprovalGate: UIToolApprovalGate,
        backgroundIntentHandlerConfiguredAtStartup: Bool
    ) {
        self.bootstrap = bootstrap
        self.viewModel = viewModel
        self.sessionManager = sessionManager
        self.toolRegistry = toolRegistry
        self.toolApprovalGate = toolApprovalGate
        self.backgroundIntentHandlerConfiguredAtStartup = backgroundIntentHandlerConfiguredAtStartup
    }

    /// Builds the composition root.
    ///
    /// Under `--uitesting` (``LaunchArguments/isUITesting``) this swaps in a
    /// deterministic test backend and an in-memory
    /// SwiftData store instead of live backends + on-disk persistence —
    /// mirrors core's `Example/Advanced/ManifoldDemoApp.swift` `init()`
    /// wiring (lines 96–119). The fixed-backend
    /// `InferenceService` initializer marks the model loaded immediately (no
    /// `loadModel` step), so the composer is enabled as soon as bootstrap
    /// finishes — no `dispatchSelectedLoad()` call is needed on that path,
    /// unlike the live-backend path below.
    ///
    /// - Parameters:
    ///   - storeName: SwiftData configuration name for the in-memory store
    ///     used under `--uitesting`. Ignored otherwise — the live path uses
    ///     `ModelContainerFactory`'s default on-disk store derived from
    ///     `configuration`.
    ///   - appName: Passed straight through to `ManifoldConfiguration`.
    ///   - bundleIdentifier: Passed straight through to
    ///     `ManifoldConfiguration` — must be distinct per app so the two
    ///     products don't collide on a shared SwiftData store path.
    static func bootstrap(
        storeName: String,
        appName: String,
        bundleIdentifier: String
    ) async throws -> AppEnvironment {
        let isUITesting = LaunchArguments.isUITesting
        let configuration = ManifoldConfiguration(appName: appName, bundleIdentifier: bundleIdentifier)

        // Consume the cross-process App Group slot before bootstrap work. Its
        // payload stays buffered until the readiness-driven delivery installed
        // below observes a loaded model.
        await AppIntentsFeature.stageInboundPayloadDuringStartup()

        // Constructed before InferenceService, on both paths below, so a
        // feature confined to Shared/Features/<Name>/ has something to
        // register a tool onto — see the type doc comment above for why
        // this can't be wired after the fact. Empty registry + the default
        // policy change no existing behavior: GenerationQueue treats a
        // zero-tool registry identically to no registry (no tools are ever
        // offered to the model either way), and `.askOncePerSession` only
        // matters once a feature actually registers a tool that gets
        // called.
        let toolRegistry = ToolRegistry()
        let toolApprovalGate = UIToolApprovalGate(policy: .askOncePerSession)

        let inferenceService: InferenceService
        if isUITesting && !LaunchArguments.runsStudioLocalModelTest {
            let backend: any InferenceBackend
            let backendName: String
            if LaunchArguments.runsToolApprovalFlow {
                backend = ToolApprovalTestBackend(root: ManifoldToolRoot.resolve())
                backendName = BackendName.ollama.rawValue
            } else {
                backend = ScriptedBackend(turns: uiTestTurns)
                backendName = LaunchArguments.showsCloudToolCatalog
                    ? APIProvider.openAIResponses.rawValue
                    : "ScriptedUITest"
            }
            inferenceService = InferenceService(
                backend: backend,
                name: backendName,
                modelName: "scripted-ui",
                toolRegistry: toolRegistry,
                toolApprovalGate: toolApprovalGate
            )
        } else {
            inferenceService = InferenceService(
                toolRegistry: toolRegistry,
                toolApprovalGate: toolApprovalGate
            )
        }

        // AskManifoldIntent runs in the background (`openAppWhenRun == false`)
        // and may be invoked without RootView ever appearing. Configure its
        // process-global handler at the earliest point its service exists.
        let backgroundIntentHandlerConfiguredAtStartup = await AppIntentsFeature.configureBackgroundIntentHandler(
            inferenceService: inferenceService
        )

        // A ternary between two closure literals here (rather than an
        // if/else assigning to an explicitly-typed local) trips Swift 6's
        // Sendable inference for the `@MainActor @Sendable` parameter type —
        // the two branches' closures don't reliably unify to the same
        // inferred type under strict concurrency checking.
        let makeModelContainer: @MainActor () throws -> ModelContainer
        if isUITesting {
            makeModelContainer = {
                let config = ModelConfiguration(storeName, isStoredInMemoryOnly: true)
                return try ModelContainerFactory.makeContainer(configurations: [config])
            }
        } else {
            makeModelContainer = { try ModelContainerFactory.makeContainer() }
        }

        let bootstrap = try ManifoldBootstrap(
            configuration: configuration,
            inferenceService: inferenceService,
            makeModelContainer: makeModelContainer
        )

        if !isUITesting || LaunchArguments.runsStudioLocalModelTest {
            OllamaBackends.register(with: inferenceService)
            CloudSaaSBackends.register(with: inferenceService)
            FoundationBackends.register(with: inferenceService)
            #if os(macOS)
            // Keep this factory ahead of the companion registrars. The core
            // lifecycle asks factories in registration order, so the Studio UI
            // suite drives its normal local-model load path with a deterministic
            // ScriptedBackend rather than constructing MLX/llama engines or
            // touching fixture paths. The real registrars still follow, proving
            // the production companion wiring can coexist with that test seam.
            if LaunchArguments.runsStudioLocalModelTest {
                inferenceService.registerBackendFactory { modelType in
                    switch modelType {
                    case .mlx, .gguf:
                        ScriptedBackend(turns: uiTestTurns)
                    default:
                        nil
                    }
                }
            }
            MLXBackends.register(with: inferenceService)
            LlamaBackends.register(with: inferenceService)
            #endif
        }

        let viewModel = ChatViewModel(
            inferenceService: inferenceService,
            toolApprovalGate: toolApprovalGate,
            conversationRuntime: bootstrap.conversationRuntime
        )
        viewModel.configure(bootstrap: bootstrap)

        if LaunchArguments.runsStudioLocalModelTest {
            // The fixture lives only in the test registry; no files are created
            // and `ScriptedBackend.loadModel` deliberately ignores these URLs.
            // Both formats must be visibly compatible before the UI can prove
            // that RootView dispatches a real load rather than only selecting a
            // switcher row.
            viewModel.modelRegistry.availableModels = Self.studioLocalModelFixtures
        }

        // `ChatViewModel` does not fetch the consumer-owned EndpointStore
        // automatically. Populate it before session restoration so a saved
        // endpoint ID can resolve, and before first-run loading so the model
        // switcher is truthful on the first rendered frame.
        do {
            viewModel.setAvailableEndpoints(try await bootstrap.endpointStore.fetchEndpoints())
        } catch {
            Log.persistence.error("Failed to load cloud endpoints: \(String(describing: error), privacy: .public)")
        }

        let sessionManager = SessionManagerViewModel()
        await sessionManager.configureAndLoad(bootstrap: bootstrap)

        if let restored = await sessionManager.selectInitialSession() {
            sessionManager.activeSession = restored
            await viewModel.switchToSession(restored)
        } else {
            // do/catch + Log — not `try?` — so a session-creation failure is
            // visible instead of silently leaving the app with no active
            // session (core's own AGENTS.md bootstrap recipe uses `try?`
            // here too; that's a known flaw in the recipe, not a pattern to
            // inherit — see Principle 6, "Errors are visible").
            do {
                let title = LaunchArguments.runsToolApprovalFlow
                    ? "Tool Approval Test"
                    : "New Chat"
                let fresh = try await sessionManager.createSession(title: title)
                sessionManager.activeSession = fresh
                await viewModel.switchToSession(fresh)
            } catch {
                Log.persistence.error("Failed to create the initial session: \(String(describing: error), privacy: .public)")
            }
        }

        if !isUITesting {
            viewModel.refreshModels()
            viewModel.autoSelectFirstRunModel()

            // Startup owns this load and awaits it. Fire-and-forget
            // dispatchSelectedLoad() allowed RootView's inbound handoff to race
            // the unloaded-model guard in ChatViewModel.ingest(_:) (#6 review).
            if viewModel.selectedEndpoint != nil {
                await viewModel.loadSelectedEndpoint()
            } else if viewModel.selectedModel != nil {
                await viewModel.loadSelectedModel()
            }
        }

        if LaunchArguments.showsAPIKeyRecovery {
            viewModel.activeError = ChatError(
                kind: .configuration,
                message: "UI test: verify the configured cloud endpoint.",
                recovery: .configureAPIKey
            )
        }

        let environment = AppEnvironment(
            bootstrap: bootstrap,
            viewModel: viewModel,
            sessionManager: sessionManager,
            toolRegistry: toolRegistry,
            toolApprovalGate: toolApprovalGate,
            backgroundIntentHandlerConfiguredAtStartup: backgroundIntentHandlerConfiguredAtStartup
        )
        // Install before returning the composition root to SwiftUI. The
        // readiness stream immediately yields `.ready` for the scripted path,
        // and holds production payloads through idle/loading until a later
        // successful model selection.
        AppIntentsFeature.install(into: environment)
        return environment
    }

    /// Refreshes the model switcher's cloud rows after the endpoint manager
    /// has added, edited, or deleted a record.
    func refreshAvailableEndpoints() async {
        do {
            viewModel.setAvailableEndpoints(try await bootstrap.endpointStore.fetchEndpoints())
        } catch {
            Log.persistence.error("Failed to refresh cloud endpoints: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deterministic scripted turns for `--uitesting` runs — enough for the
    /// smoke suite's single send/receive round trip. `ScriptedBackend`
    /// returns an empty terminal turn once these are exhausted, which the
    /// turn loop treats as "no more tool calls, stop" rather than an error,
    /// so running out mid-session is harmless.
    private static var uiTestTurns: [ScriptedBackend.Turn] {
        if LaunchArguments.runsAppIntentToolTurn {
            return [
                .toolCall(
                    name: "set_reminder_intent",
                    arguments: #"{"text":"review the live registry"}"#
                ),
                .tokens(["Reminder", " completed", " through", " the", " live", " registry", "."]),
            ]
        }
        return [
            .tokens(["Hello", " from", " the", " scripted", " UI-test", " backend", "."]),
            .tokens(["Sure", ",", " happy", " to", " help", "."]),
            .tokens(["Got", " it", "."]),
        ]
    }

    /// Small, deterministic local-model catalogue used exclusively by the
    /// Studio macOS UI target. Tiny declared sizes keep the genuine load-plan
    /// path in its allowed state while never requiring an actual model asset.
    private static var studioLocalModelFixtures: [ModelInfo] {
        [
            ModelInfo(
                name: "Studio Fixture MLX",
                fileName: "studio-fixture-mlx",
                url: URL(fileURLWithPath: "/tmp/manifold-studio-fixture-mlx"),
                fileSize: 1,
                modelType: .mlx
            ),
            ModelInfo(
                name: "Studio Fixture GGUF",
                fileName: "studio-fixture-gguf.gguf",
                url: URL(fileURLWithPath: "/tmp/manifold-studio-fixture-gguf.gguf"),
                fileSize: 1,
                modelType: .gguf
            ),
        ]
    }
}

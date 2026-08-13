import Foundation
import SwiftData
import ManifoldKit
import ManifoldTools

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
    var themePreset: ThemingPreset = .standard

    var theme: ManifoldTheme {
        themePreset.theme
    }

    private init(
        bootstrap: ManifoldBootstrap,
        viewModel: ChatViewModel,
        sessionManager: SessionManagerViewModel,
        toolRegistry: ToolRegistry,
        toolApprovalGate: UIToolApprovalGate
    ) {
        self.bootstrap = bootstrap
        self.viewModel = viewModel
        self.sessionManager = sessionManager
        self.toolRegistry = toolRegistry
        self.toolApprovalGate = toolApprovalGate
    }

    /// Builds the composition root.
    ///
    /// Under `--uitesting` (``LaunchArguments/isUITesting``) this swaps in a
    /// deterministic `ScriptedBackend` (`ManifoldTools`) and an in-memory
    /// SwiftData store instead of live backends + on-disk persistence —
    /// mirrors core's `Example/Advanced/ManifoldDemoApp.swift` `init()`
    /// wiring (lines 96–119). `ScriptedBackend`'s fixed-backend
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
        if isUITesting {
            let scripted = ScriptedBackend(turns: uiTestTurns)
            inferenceService = InferenceService(
                backend: scripted,
                name: "ScriptedUITest",
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

        if !isUITesting {
            OllamaBackends.register(with: inferenceService)
            CloudSaaSBackends.register(with: inferenceService)
            FoundationBackends.register(with: inferenceService)
        }

        let viewModel = ChatViewModel(
            inferenceService: inferenceService,
            toolApprovalGate: toolApprovalGate,
            conversationRuntime: bootstrap.conversationRuntime
        )
        viewModel.configure(bootstrap: bootstrap)

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
                let fresh = try await sessionManager.createSession()
                sessionManager.activeSession = fresh
                await viewModel.switchToSession(fresh)
            } catch {
                Log.persistence.error("Failed to create the initial session: \(String(describing: error), privacy: .public)")
            }
        }

        if !isUITesting {
            viewModel.refreshModels()
            viewModel.autoSelectFirstRunModel()
            viewModel.dispatchSelectedLoad()
        }

        if LaunchArguments.showsAPIKeyRecovery {
            viewModel.activeError = ChatError(
                kind: .configuration,
                message: "UI test: verify the configured cloud endpoint.",
                recovery: .configureAPIKey
            )
        }

        return AppEnvironment(
            bootstrap: bootstrap,
            viewModel: viewModel,
            sessionManager: sessionManager,
            toolRegistry: toolRegistry,
            toolApprovalGate: toolApprovalGate
        )
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
    private static let uiTestTurns: [ScriptedBackend.Turn] = [
        .tokens(["Hello", " from", " the", " scripted", " UI-test", " backend", "."]),
        .tokens(["Sure", ",", " happy", " to", " help", "."]),
        .tokens(["Got", " it", "."]),
    ]
}

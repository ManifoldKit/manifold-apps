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
@MainActor
@Observable
final class AppEnvironment {
    let bootstrap: ManifoldBootstrap
    let viewModel: ChatViewModel
    let sessionManager: SessionManagerViewModel
    var theme: ManifoldTheme = .standard

    private init(
        bootstrap: ManifoldBootstrap,
        viewModel: ChatViewModel,
        sessionManager: SessionManagerViewModel
    ) {
        self.bootstrap = bootstrap
        self.viewModel = viewModel
        self.sessionManager = sessionManager
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

        let inferenceService: InferenceService
        if isUITesting {
            let scripted = ScriptedBackend(turns: uiTestTurns)
            inferenceService = InferenceService(
                backend: scripted,
                name: "ScriptedUITest",
                modelName: "scripted-ui"
            )
        } else {
            inferenceService = InferenceService()
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
            conversationRuntime: bootstrap.conversationRuntime
        )
        viewModel.configure(bootstrap: bootstrap)

        let sessionManager = SessionManagerViewModel()
        await sessionManager.configureAndLoad(bootstrap: bootstrap)

        if let restored = await sessionManager.selectInitialSession() {
            sessionManager.activeSession = restored
            await viewModel.switchToSession(restored)
        } else if let fresh = try? await sessionManager.createSession() {
            sessionManager.activeSession = fresh
            await viewModel.switchToSession(fresh)
        }

        if !isUITesting {
            viewModel.refreshModels()
            viewModel.autoSelectFirstRunModel()
            viewModel.dispatchSelectedLoad()
        }

        return AppEnvironment(bootstrap: bootstrap, viewModel: viewModel, sessionManager: sessionManager)
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

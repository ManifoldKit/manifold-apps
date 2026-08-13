import Foundation
import ManifoldInference
import ManifoldTools

/// Composition root for the Tools feature's toolset.
///
/// Resolves an app-owned sandbox directory, seeds it with a small fixture
/// "workspace" on first launch, and registers the reference toolset on a
/// `ToolRegistry`. The seeded fixture exists so the hero tool
/// (`SampleRepoSearchTool`) has something to search without the user having
/// to drop their own files in.
///
/// Ported from ManifoldKit's `Example/Advanced/DemoTools.swift` (`DemoTools`
/// enum) — same registration shape, renamed to avoid colliding with the
/// `ManifoldTools` package product this file imports.
enum ManifoldToolset {

    /// Names of the tools registered by ``register(on:root:)``. A later
    /// Scenarios feature (if ported) can use this to reset to the baseline
    /// set between scenarios, mirroring core's `DemoScenarioRunner`.
    static let baselineNames: [String] = [
        "calc",
        "now",
        "read_file",
        "list_dir",
        "sample_repo_search",
        "write_file"
    ] + FailureTools.names

    /// The deliberately small catalog offered to local and unknown backends.
    /// Small instruct models lose reliability as the number of tool schemas
    /// grows; ManifoldKit's consumer guidance sets five as the practical
    /// ceiling for local 3B–8B models. Executors outside this set remain
    /// registered for dispatch and become advertised on known cloud paths.
    static let localAdvertisedNames: Set<String> = [
        "calc",
        "now",
        "read_file",
        "sample_repo_search",
        "write_file",
    ]

    /// Registers the full reference toolset on `registry`.
    ///
    /// Runs synchronously on the main actor because `ToolRegistry` is
    /// MainActor-isolated. Seeding is idempotent — the on-disk fixture is
    /// only written when absent, so repeated launches are cheap.
    @MainActor
    static func register(on registry: ToolRegistry, root: URL = ManifoldToolRoot.resolve()) {
        do {
            try ManifoldToolRoot.seedIfNeeded(at: root)
        } catch {
            // Fail open: the tools still work for files the user adds later,
            // and the seed content is a nice-to-have rather than a contract.
            Log.inference.warning("ManifoldToolset: failed to seed fixture workspace at \(root.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }

        registry.register(CalcTool.makeExecutor())
        registry.register(ManifoldNowTool.makeExecutor())
        registry.register(ReadFileTool.makeExecutor(root: root))
        registry.register(ListDirTool.makeExecutor(root: root))
        registry.register(SampleRepoSearchTool.makeExecutor(root: root))
        registry.register(WriteFileTool.makeExecutor(root: root))
        FailureTools.register(on: registry)
    }

    /// Curates the schemas offered to the active model without removing any
    /// executor from the registry. This switches exhaustively over v0.75's
    /// published `APIProvider` identities because cloud lifecycle descriptors
    /// use those stable provider codes as `activeBackendName` (not every code,
    /// notably `openAIResponses`, is a `BackendName` well-known constant).
    /// Remote/API-key providers receive the full reference/failure catalog;
    /// Ollama, LM Studio, and unrecognised identities stay at the conservative
    /// five-tool ceiling.
    @MainActor
    static func updateAdvertisement(on registry: ToolRegistry, backendName: String?) {
        switch backendName.flatMap(APIProvider.parse) {
        case .openAI, .openAIResponses, .claude, .custom:
            registry.advertisedToolNames = nil
        case .ollama, .lmStudio, nil:
            registry.advertisedToolNames = localAdvertisedNames
        }
    }
}

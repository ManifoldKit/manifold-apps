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
}

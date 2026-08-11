import Foundation

/// Resolves and seeds the app's filesystem-tool sandbox.
///
/// Ported from ManifoldKit's `Example/Advanced/DemoTools.swift`
/// (`DemoToolRoot`) — same sandbox/seed contract, renamed for this app.
enum ManifoldToolRoot {

    /// Returns the app-owned sandbox root. Creates the parent directory lazily.
    ///
    /// Under `--uitesting`, the caller passes a per-launch temp directory
    /// instead (mirrors core's `ManifoldDemoApp.resolveSandboxRoot(isTesting:)`)
    /// so XCUITests leave no residue in Application Support.
    static func resolve() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.temporaryDirectory

        let root = base
            .appendingPathComponent("Manifold", isDirectory: true)
            .appendingPathComponent("ToolRoot", isDirectory: true)

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes the bundled fixture workspace under `root` when it isn't there.
    ///
    /// The seed is keyed by a marker file; we do not diff contents across
    /// launches. If the user edits a seeded file we respect their choice. If
    /// they delete the entire workspace (leaving only the marker, or nothing
    /// at all) we re-seed so tools that search the fixture don't silently
    /// look broken.
    static func seedIfNeeded(at root: URL) throws {
        let fm = FileManager.default
        let marker = root.appendingPathComponent(".seeded", isDirectory: false)

        if fm.fileExists(atPath: marker.path) {
            // Re-seed only when the marker is the sole survivor — not when
            // user content lives alongside it.
            let contents = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            let nonMarker = contents.filter { $0 != ".seeded" }
            if !nonMarker.isEmpty { return }
        }

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, contents) in Self.fixture {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try Data("1".utf8).write(to: marker)
    }

    private static let fixture: [(String, String)] = [
        ("README.md", """
        # Sample Workspace

        This is a small fixture workspace the Tools feature uses to showcase
        tool calling. Ask the assistant to summarize the README files, search
        for a keyword, or read a specific file — it will invoke the sandboxed
        filesystem tools.
        """),
        ("notes/ideas.md", """
        # Product Ideas

        - Offline-first note app with local embeddings.
        - A CLI that replays a chat transcript through a different model.
        - Voice memos transcribed via on-device speech, summarized at close of day.
        - A fuzzer harness for long-context chat backends.
        """),
        ("docs/architecture.md", """
        # Architecture Overview

        ManifoldKit exposes these core products:
        - ManifoldInference — protocols and orchestration.
        - ManifoldRuntime — persistence-free runtime services and ports.
        - ManifoldPersistenceSwiftData — SwiftData persistence and bootstrap.
        - ManifoldUI — SwiftUI views and view models.
        - ManifoldTools — reference tools and the fuzzing harness.
        """),
        ("docs/tool-calling.md", """
        # Tool Calling

        Register a ToolExecutor on the ToolRegistry you pass to InferenceService.
        The GenerationCoordinator dispatches ToolCall events through the registry
        and threads the ToolResult back into the conversation.
        """),
        ("shopping-list.txt", """
        milk
        eggs
        coffee
        olive oil
        """),
    ]
}

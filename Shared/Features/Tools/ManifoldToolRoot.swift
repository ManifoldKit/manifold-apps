import Foundation
import ManifoldInference

/// Resolves and seeds the app's filesystem-tool sandbox.
///
/// Ported from ManifoldKit's `Example/Advanced/DemoTools.swift`
/// (`DemoToolRoot`) — same sandbox/seed contract, renamed for this app.
enum ManifoldToolRoot {

    /// Returns the app-owned sandbox root. Creates the parent directory lazily.
    ///
    /// Under `--uitesting`, resolves a per-process temp directory so XCUITests
    /// leave no residue in Application Support.
    static func resolve() -> URL {
        let fm = FileManager.default
        if LaunchArguments.isUITesting || LaunchArguments.runsMacRealModelTest {
            return uiTestingRoot
        }

        let base: URL
        do {
            base = try fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        } catch {
            Log.inference.warning("ManifoldToolRoot: failed to resolve Application Support; using the temporary directory: \(String(describing: error), privacy: .public)")
            base = fm.temporaryDirectory
        }

        let root = base
            .appendingPathComponent("Manifold", isDirectory: true)
            .appendingPathComponent("ToolRoot", isDirectory: true)

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Log.inference.warning("ManifoldToolRoot: failed to create tool root at \(root.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return root
    }

    /// Writes the bundled fixture workspace under `root` when it isn't there.
    ///
    /// The seed is keyed by a marker file. Qualification fixtures added after
    /// the first release are created when absent; the old shopping list is
    /// upgraded only when it still exactly matches the shipped legacy value.
    /// User edits are never overwritten. If the user deletes the entire
    /// workspace (leaving only the marker, or nothing at all) we re-seed so
    /// tools that search the fixture don't silently look broken.
    static func seedIfNeeded(at root: URL) throws {
        let fm = FileManager.default
        let marker = root.appendingPathComponent(".seeded", isDirectory: false)

        if LaunchArguments.seedsLegacyQualificationFixture,
           !fm.fileExists(atPath: marker.path) {
            try stageLegacyFixture(at: root)
        }

        if fm.fileExists(atPath: marker.path) {
            // Re-seed only when the marker is the sole survivor — not when
            // user content lives alongside it.
            let contents = try fm.contentsOfDirectory(atPath: root.path)
            let nonMarker = contents.filter { $0 != ".seeded" }
            if !nonMarker.isEmpty {
                try migrateQualificationFixturesIfNeeded(at: root)
                return
            }
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

    private static func migrateQualificationFixturesIfNeeded(at root: URL) throws {
        let fm = FileManager.default
        for (path, contents) in qualificationFixtures {
            let url = root.appendingPathComponent(path)
            if path == "shopping-list.txt", fm.fileExists(atPath: url.path) {
                let existing = try String(contentsOf: url, encoding: .utf8)
                guard existing == legacyShoppingList else { continue }
            } else if fm.fileExists(atPath: url.path) {
                continue
            }
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func stageLegacyFixture(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyShoppingList.write(
            to: root.appendingPathComponent("shopping-list.txt"),
            atomically: true,
            encoding: .utf8
        )
        try Data("1".utf8).write(to: root.appendingPathComponent(".seeded"))
    }

    private static let legacyShoppingList = """
    milk
    eggs
    coffee
    olive oil
    """

    private static let qualificationFixtures: [(String, String)] = [
        ("shopping-list.txt", """
        apples: 12.50
        rice: 7.25
        saffron: 41.00

        Budget note: buy apples and rice; skip saffron.
        """),
        ("readmes/backend-a.md", """
        # Backend A

        Shared marker: DEMO-README-NONCE.

        Backend A uses streaming tools for incremental tool-call arguments.
        """),
        ("readmes/backend-b.md", """
        # Backend B

        Shared marker: DEMO-README-NONCE.

        Backend B uses batch tools for whole-call dispatch.
        """),
    ]

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
        qualificationFixtures[0],
        qualificationFixtures[1],
        qualificationFixtures[2],
    ]

    private static let uiTestingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ManifoldToolsUITest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
}

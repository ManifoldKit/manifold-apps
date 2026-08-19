import Foundation

/// Parses process launch arguments the app and its UI tests agree on.
enum LaunchArguments {
    /// True when the app was launched with `--uitesting` (set by
    /// `ManifoldUITests`' `launchApp()`). Selects the deterministic
    /// `ScriptedBackend` inference path and an in-memory persistence store —
    /// see `AppEnvironment.bootstrap(storeName:appName:bundleIdentifier:)`.
    static var isUITesting: Bool {
        CommandLine.arguments.contains("--uitesting")
    }

    /// Enables the macOS Manifold local-model UI regression fixture. This stays
    /// nested under `--uitesting` so production never receives synthetic
    /// models or a scripted local-model factory.
    static var runsMacLocalModelTest: Bool {
        isUITesting && CommandLine.arguments.contains("--mac-local-model-test")
    }

    /// Enables the opt-in Manifold Mac hardware gate. Unlike
    /// ``runsMacLocalModelTest``, this is deliberately a live inference
    /// path: it discovers two installed model assets and lets the normal
    /// RootView selection dispatch load MLX and llama.cpp backends. It may be
    /// combined with `--uitesting` solely to get the ephemeral SwiftData store;
    /// it must never select the scripted backend or fixture catalogue.
    static var runsMacRealModelTest: Bool {
        CommandLine.arguments.contains("--mac-real-model-test")
    }

    /// Enables the physical-iOS Foundation Models release gate. The launch
    /// remains under `--uitesting` for an isolated SwiftData store, but must
    /// use the production inference service and backend registration rather
    /// than the deterministic `ScriptedBackend`.
    static var runsIOSRealFoundationTest: Bool {
        isUITesting && CommandLine.arguments.contains("--ios-real-foundation-test")
    }

    /// The installed MLX directory exercised by the Manifold Mac hardware gate.
    /// The shell gate passes this through explicitly, while the default keeps
    /// the one-command local workflow useful on the maintainer's machine.
    static var macRealMLXModelURL: URL {
        modelURL(
            environmentKey: "MANIFOLD_MAC_REAL_MLX_MODEL_PATH",
            defaultPath: "~/Documents/Models/mlx/Qwen3.5-2B-4bit"
        )
    }

    /// The installed GGUF file exercised by the Manifold Mac hardware gate.
    static var macRealGGUFModelURL: URL {
        modelURL(
            environmentKey: "MANIFOLD_MAC_REAL_GGUF_MODEL_PATH",
            defaultPath: "~/Documents/Models/gguf/Qwen3.5-2B/Qwen_Qwen3.5-2B-Q4_K_M.gguf"
        )
    }

    /// Shell-validated weight bytes for the hardware-gate MLX directory.
    /// Passing this across the XCTest process boundary avoids enumerating a
    /// TCC-protected Documents directory during app bootstrap.
    static var macRealMLXModelBytes: UInt64? {
        modelBytes(environmentKey: "MANIFOLD_MAC_REAL_MLX_MODEL_BYTES")
    }

    /// Shell-validated byte size for the hardware-gate GGUF file.
    static var macRealGGUFModelBytes: UInt64? {
        modelBytes(environmentKey: "MANIFOLD_MAC_REAL_GGUF_MODEL_BYTES")
    }

    /// Seeds ChatView's real API-key recovery banner for the endpoint-store
    /// UI regression. Kept separate from `--uitesting` so the smoke suite's
    /// normal launch state is unchanged.
    static var showsAPIKeyRecovery: Bool {
        isUITesting && CommandLine.arguments.contains("--show-api-key-recovery")
    }

    /// Selects the history-aware approval-flow backend and inline approval
    /// presentation used by `ToolsUITests`. Kept opt-in so the ordinary smoke
    /// tests retain their token-only scripted turns.
    static var runsToolApprovalFlow: Bool {
        isUITesting && CommandLine.arguments.contains("--tool-approval-test")
    }

    /// Gives the deterministic backend the published OpenAI Responses provider
    /// identity so the Tools browser can prove the full reference catalog
    /// remains available on that cloud path without contacting a live provider.
    static var showsCloudToolCatalog: Bool {
        isUITesting && CommandLine.arguments.contains("--cloud-tool-catalog-test")
    }

    /// Seeds the real App Group envelope before composition begins so the UI
    /// suite can exercise AppIntentsFeature's production read/buffer/deliver
    /// path inside the app process. Simulator UI-test runners are ad-hoc
    /// signed without application-group entitlements, so they cannot seed the
    /// app's suite cross-process even though device builds carry the group.
    static var appIntentPrompt: String? {
        guard isUITesting else { return nil }
        return value(after: "--appintent-prompt")
    }

    /// Seeds an App Group envelope only after `RootView` is live, so the UI
    /// suite can drive the real warm-scene `onOpenURL` handoff rather than the
    /// cold-start bootstrap read. Never activates outside `--uitesting`.
    static var warmAppIntentPrompt: String? {
        guard isUITesting else { return nil }
        return value(after: "--warm-appintent-prompt")
    }

    /// Writes deliberately malformed App Group data for the degraded-path UI
    /// assertion. Never active outside deterministic UI-test launches.
    static var seedsMalformedAppIntentEnvelope: Bool {
        isUITesting && CommandLine.arguments.contains("--appintent-malformed-envelope")
    }

    /// Selects a scripted tool-calling turn that can only complete when the
    /// AppIntent executor is registered on InferenceService's actual registry.
    static var runsAppIntentToolTurn: Bool {
        isUITesting && CommandLine.arguments.contains("--appintent-tool-turn")
    }

    /// The value following `--scenario <id>`, if present. Reserved for the
    /// future `ScenariosFeature` (mirrors core's `--bck-demo-scenario`);
    /// unused until that feature is ported.
    static var scenario: String? {
        value(after: "--scenario")
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    private static func modelURL(environmentKey: String, defaultPath: String) -> URL {
        let path = ProcessInfo.processInfo.environment[environmentKey] ?? defaultPath
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private static func modelBytes(environmentKey: String) -> UInt64? {
        guard let rawValue = ProcessInfo.processInfo.environment[environmentKey],
              let bytes = UInt64(rawValue),
              bytes > 0 else {
            return nil
        }
        return bytes
    }
}

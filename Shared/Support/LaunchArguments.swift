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
    /// path across the app-process boundary.
    static var appIntentPrompt: String? {
        guard isUITesting else { return nil }
        return value(after: "--appintent-prompt")
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
}

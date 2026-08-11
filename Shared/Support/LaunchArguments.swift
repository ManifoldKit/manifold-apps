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

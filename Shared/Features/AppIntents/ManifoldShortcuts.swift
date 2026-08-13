import AppIntents
import ManifoldAppIntents

/// Surfaces ``AskManifoldAppIntent`` (and, once `ManifoldAppIntents` is
/// linked, the library-provided `AskManifoldIntent`) to Spotlight / Siri so
/// users can invoke them by voice or from the keyboard without opening the
/// app first.
///
/// Ported from ManifoldKit's own
/// `Example/Advanced/Intents/ManifoldDemoShortcuts.swift` — renamed to drop
/// "Demo" branding. Phrases use `.applicationName` rather than a literal
/// app name so the same shortcut text reads correctly whether the host
/// bundle is `Manifold` (iOS) or `Manifold Studio` (macOS) — this file is
/// compiled into both targets.
///
/// ## AppShortcutsProvider must live in the host bundle
///
/// The AppIntents build toolchain discovers shortcut phrase metadata at
/// build time by scanning main-bundle and app-extension sources for
/// `.stringsdata` extraction. Framework-only declarations (like a future
/// library `AskManifoldIntent`) are not indexed — only this
/// `AppShortcutsProvider` wrapper needs to be in the host bundle, which is
/// exactly where `Shared/` sources land.
public struct ManifoldShortcuts: AppShortcutsProvider {

    @available(iOS 18, macOS 15, *)
    public static var appShortcuts: [AppShortcut] {
        // `prompt` is a plain `String`, which Siri's phrase-binding syntax
        // (`\(\.$prompt)`) does not allow — only `AppEntity`/`AppEnum`
        // parameters can appear inside phrases. Siri prompts for the text
        // at invocation time instead.
        AppShortcut(
            intent: AskManifoldAppIntent(),
            phrases: [
                "Ask \(.applicationName)"
            ],
            shortTitle: "Ask",
            systemImageName: "text.bubble"
        )

        // AskManifoldIntent is the library-provided intent that routes
        // through whatever handler the host wired via
        // ManifoldIntentConfiguration (see RuntimeHandler.swift). Unlike
        // AskManifoldAppIntent, it does not open the app — it answers via
        // Siri directly (openAppWhenRun == false on the library type).
        AppShortcut(
            intent: AskManifoldIntent(),
            phrases: [
                "Ask \(.applicationName) without opening"
            ],
            shortTitle: "Ask (background)",
            systemImageName: "text.bubble.fill"
        )
    }
}

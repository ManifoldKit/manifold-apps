import SwiftUI

/// Theme picker driving `AppEnvironment.theme` (manifold-apps W2 P6) — ports
/// the preset-picker "worked example" from ManifoldKit's own
/// `Example/Advanced/DemoContentView.swift` (`DemoChatTheme` + the
/// "Appearance" toolbar menu). `RootView` already cascades the selected
/// preset app-wide; this feature's job is only to
/// present a picker that writes it. See `ThemingShowcaseView` for the view
/// itself.
enum ThemingFeature: AppFeature {
    static let id = "theming"
    static let title = "Theming"
    static let systemImage = "paintpalette"

    /// No tool sources, hooks, or session wiring to install — the theme
    /// picker only ever writes `AppEnvironment.theme`, which `RootView`
    /// already reads on every render.
    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(ThemingShowcaseView(env: env))
    }
}

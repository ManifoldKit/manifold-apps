import SwiftUI

/// Installs the app's reference toolset and exposes a browser for the live
/// registry plus its approval policy.
enum ToolsFeature: AppFeature {
    static let id = "tools"
    static let title = "Tools"
    static let systemImage = "wrench.and.screwdriver"

    static func install(into env: AppEnvironment) {
        ManifoldToolset.register(on: env.toolRegistry)
    }

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(ToolsBrowserView(env: env))
    }
}

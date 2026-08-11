import SwiftUI

/// Stub — tool-calling registry + approval UI (manifold-apps W2 P1). A
/// later worker replaces only `install(into:)`/`makeView(env:)` below.
enum ToolsFeature: AppFeature {
    static let id = "tools"
    static let title = "Tools"
    static let systemImage = "wrench.and.screwdriver"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(NotYetPortedView(title: title))
    }
}

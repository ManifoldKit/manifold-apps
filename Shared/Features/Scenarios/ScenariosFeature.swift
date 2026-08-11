import SwiftUI

/// Stub — scripted-scenario runner (manifold-apps W3 P2). A later worker
/// replaces only `install(into:)`/`makeView(env:)` below.
enum ScenariosFeature: AppFeature {
    static let id = "scenarios"
    static let title = "Scenarios"
    static let systemImage = "play.rectangle.on.rectangle"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(NotYetPortedView(title: title))
    }
}

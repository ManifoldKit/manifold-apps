import SwiftUI

/// Stub — cloud endpoint management (manifold-apps W2 P3). A later worker
/// replaces only `install(into:)`/`makeView(env:)` below.
enum CloudFeature: AppFeature {
    static let id = "cloud"
    static let title = "Cloud"
    static let systemImage = "cloud"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(NotYetPortedView(title: title))
    }
}

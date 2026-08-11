import SwiftUI

/// Stub — theme picker driving `AppEnvironment.theme` (manifold-apps W2
/// P6). A later worker replaces only `install(into:)`/`makeView(env:)`
/// below.
enum ThemingFeature: AppFeature {
    static let id = "theming"
    static let title = "Theming"
    static let systemImage = "paintpalette"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(NotYetPortedView(title: title))
    }
}

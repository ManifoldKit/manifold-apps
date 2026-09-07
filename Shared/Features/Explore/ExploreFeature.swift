import SwiftUI

/// A finished, always-available collection of native Manifold examples.
///
/// This is intentionally not an onboarding gate. It never creates a session,
/// loads a model, or changes persisted model and endpoint selections.
enum ExploreFeature: AppFeature {
    static let id = "explore"
    static let title = "Explore"
    static let systemImage = "sparkles"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(ExploreView(env: env))
    }
}

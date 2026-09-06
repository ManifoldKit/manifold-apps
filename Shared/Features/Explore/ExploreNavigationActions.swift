import SwiftUI

/// Host-owned routes from Explore into the existing setup surfaces.
///
/// Explore deliberately owns no model registry, endpoint store, or sheet
/// presentation. `RootView` supplies these actions at composition time because
/// it already owns each route's state and lifecycle. The environment value is
/// optional: an un-wired preview omits setup controls rather than displaying
/// an inert button.
@MainActor
struct ExploreNavigationActions {
    let showModels: () -> Void
    let showCloud: () -> Void
}

private struct ExploreNavigationActionsKey: EnvironmentKey {
    static let defaultValue: ExploreNavigationActions? = nil
}

extension EnvironmentValues {
    var exploreNavigationActions: ExploreNavigationActions? {
        get { self[ExploreNavigationActionsKey.self] }
        set { self[ExploreNavigationActionsKey.self] = newValue }
    }
}

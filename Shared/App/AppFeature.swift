import SwiftUI

/// One entry in the platform feature registries (``MobileFeatureRegistry``,
/// ``MacFeatureRegistry``). Each conforming type is a self-contained
/// surface ``RootView`` can navigate to from the sidebar — a tool-calling
/// scenario runner, a cloud endpoint manager, an MCP client, and so on.
///
/// This protocol is the ONE seam later, parallel workers replace stub
/// bodies through — `install(into:)` and `makeView(env:)`. Nothing else in
/// `Shared/App/` should need to change as features get ported (that is the
/// whole point of the seam: it gets written once, tonight, so four-plus
/// workers can land features in parallel without touching the same file).
@MainActor
protocol AppFeature {
    /// Stable identifier used for sidebar selection state. Never change an
    /// existing feature's `id` once it ships — it round-trips through
    /// `RootView`'s `selectedFeatureID` state.
    static var id: String { get }

    /// Sidebar row title.
    static var title: String { get }

    /// Sidebar row SF Symbol name.
    static var systemImage: String { get }

    /// Called once, at `RootView`'s first appearance, to install any tool
    /// sources / hooks / session-tool-sources this feature needs into the
    /// shared `AppEnvironment`. Stub features leave this empty.
    static func install(into env: AppEnvironment)

    /// Builds the feature's detail view, shown in place of `ChatView` while
    /// this feature is selected in the sidebar.
    static func makeView(env: AppEnvironment) -> AnyView
}

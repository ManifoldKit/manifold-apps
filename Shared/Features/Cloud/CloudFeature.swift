import SwiftUI
import ManifoldUIModelManagement

/// Cloud API endpoint management — list, add, edit, and delete OpenAI /
/// Claude / Ollama / custom OpenAI-compatible endpoints.
///
/// **Naming note (found during this port):** core's `Example/Advanced/`
/// has a same-named-sounding-but-unrelated `ConnectedServicesView` that
/// manages MCP tool-server connections, not cloud LLM endpoints — that
/// surface is ``MCPFeature``, not this one. The view that actually matches
/// "endpoint list, add/edit cloud endpoints" is `APIConfigurationView`
/// (`ManifoldUIModelManagement`), which core wires via `ChatView`'s
/// `.chatAPIConfiguration { APIConfigurationView() }` seam
/// (`Example/Advanced/DemoContentView.swift`) — reachable there through
/// Generation Settings → "Manage Cloud APIs". This feature exposes the same
/// view directly from the sidebar instead, matching this app's per-feature
/// navigation shape.
///
/// `APIConfigurationView` owns its own list/add/edit/delete flow end to end
/// (backed by `EndpointStore`, with Keychain cleanup on delete) — there is
/// nothing left for this feature to build; it only has to adapt the view to
/// the environment it needs.
///
/// "Route to backend" (making a saved endpoint the active one) remains in
/// `RootView`'s model switcher. The host refreshes `availableEndpoints` when
/// this screen is left, then dispatches the selected endpoint load; setting
/// `selectedEndpoint` alone only records intent at ManifoldKit v0.75.0.
enum CloudFeature: AppFeature {
    static let id = "cloud"
    static let title = "Cloud"
    static let systemImage = "cloud"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        // `APIConfigurationView` reads/writes through
        // `@Environment(\.endpointStore)`. Inject it here directly from
        // `env.bootstrap.endpointStore` (the canonical AGENTS.md bootstrap
        // recipe's `.environment(\.endpointStore, bootstrap.endpointStore)`
        // line) rather than relying on it being wired further up the view
        // tree — this feature is reached straight from the sidebar, so it
        // does its own injection instead of assuming an ancestor did it.
        AnyView(
            APIConfigurationView()
                .environment(\.endpointStore, env.bootstrap.endpointStore)
        )
    }
}

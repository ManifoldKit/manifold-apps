import SwiftUI

/// Stub — MCP client surface (manifold-apps W3 P4). macOS-only — see
/// ``MacFeatureRegistry`` vs ``MobileFeatureRegistry``. A later worker
/// replaces only `install(into:)`/`makeView(env:)` below.
enum MCPFeature: AppFeature {
    static let id = "mcp"
    static let title = "MCP"
    static let systemImage = "server.rack"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(NotYetPortedView(title: title))
    }
}

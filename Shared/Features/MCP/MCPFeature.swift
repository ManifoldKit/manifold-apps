import SwiftUI

/// The macOS MCP connection surface. It deliberately manages only server
/// connections and their lifecycle; chat tool execution is separate work.
enum MCPFeature: AppFeature {
    static let id = "mcp"
    static let title = "MCP"
    static let systemImage = "server.rack"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        AnyView(MCPConnectionsView())
        #else
        AnyView(NotYetPortedView(title: title))
        #endif
    }
}

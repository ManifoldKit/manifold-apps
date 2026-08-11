import SwiftUI

/// Stub — AppIntent ↔ ToolDefinition bridge + inbound-payload handoff
/// (manifold-apps W2 P5). Also the eventual home for wiring
/// `Shared/Support/InboundPayload/` into `AppEnvironment`. A later worker
/// replaces only `install(into:)`/`makeView(env:)` below.
enum AppIntentsFeature: AppFeature {
    static let id = "appintents"
    static let title = "App Intents"
    static let systemImage = "bolt.badge.a"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(NotYetPortedView(title: title))
    }
}

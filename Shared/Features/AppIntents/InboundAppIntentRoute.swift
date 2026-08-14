import Foundation

/// The URL handoff contract between `AskManifoldAppIntent` and a running iOS
/// scene. `openAppWhenRun` alone is not a delivery event for an already-active
/// scene; opening this URL is.
enum InboundAppIntentRoute {
    static let scheme = "manifold"
    static let host = "ingest"
    static let url = URL(string: "\(scheme)://\(host)")!

    static func isInboundURL(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame
            && url.host?.caseInsensitiveCompare(host) == .orderedSame
            && url.path.isEmpty
    }
}

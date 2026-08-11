import Foundation

/// Codable payload written to the App Group container by a future Share or
/// Action Extension and drained by the host app on the next foreground
/// transition.
///
/// This type is intentionally **pure Foundation** — no ManifoldKit
/// dependency — so it can be compiled into both the host app and a future
/// lightweight extension target, which must stay under the iOS extension
/// memory budget. Ported near-verbatim from ManifoldKit's own
/// `Example/Advanced/Extensions/PendingSharePayload.swift` ahead of the
/// Extensions feature work that will actually produce/consume it.
///
/// ## Wire format
///
/// A future extension writes a JSON-encoded `PendingSharePayload` to:
/// - App Group: ``ManifoldSharedAppGroup/identifier``
/// - Key: ``ManifoldSharedAppGroup/pendingShareKey``
///
/// The host app is expected to read it on foreground and convert it to a
/// `PendingPayload` before calling
/// `ChatViewModel.ingestPendingPayload(_:intent:)` — not yet wired in this
/// scaffold.
///
/// ## Payload priority
///
/// If an extension finds multiple item types it should queue only one
/// payload per invocation; the exact priority is up to the producing
/// extension.
struct PendingSharePayload: Codable, Sendable {

    /// The flavour of content the extension captured.
    enum Kind: String, Codable {
        case text
        case url
        case image
    }

    /// The flavour of content this payload carries.
    var kind: Kind

    /// Plain-text body — populated when `kind == .text`.
    var text: String? = nil

    /// Absolute string of the shared URL — populated when `kind == .url`.
    var urlString: String? = nil

    /// Raw image bytes — populated when `kind == .image`.
    var imageData: Data? = nil

    /// MIME type for `imageData`; defaults to `"image/png"` at the read site
    /// when absent.
    var imageMimeType: String? = nil

    /// Entry point that produced this payload.
    ///
    /// - `"shareExtension"`: iOS/macOS Share sheet
    /// - `"actionExtension"`: iOS Action sheet ("Summarise selection")
    var source: String
}

/// App Group constants shared between the host app and a future Share/Action
/// extension. The host app's ``ManifoldAppGroup`` enum re-exports the same
/// identifiers — keep the two in sync (the constants live here so a future
/// extension target, which can't import host-app types, still sees them).
enum ManifoldSharedAppGroup {
    /// App Group identifier — must match the entitlement declared by the
    /// host app and any future extension targets once they exist.
    static let identifier = "group.com.manifoldkit.apps"

    /// `UserDefaults` key a future extension writes to and the host app
    /// drains.
    static let pendingShareKey = "manifold.pending-share"
}

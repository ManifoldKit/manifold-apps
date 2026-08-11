import Foundation
import ManifoldInference

/// JSON envelope written to App Group defaults by a future inbound-handoff
/// writer (an App Intent) and read back by the host app's `.onOpenURL`
/// handler. Ported near-verbatim from ManifoldKit's own
/// `Example/Advanced/Intents/InboundPayloadEnvelope.swift` ahead of the
/// AppIntents/Extensions feature work that will actually wire it up
/// (manifold-apps W2/W3) — kept in `Shared/Support/` rather than a feature
/// directory because both the future AppIntents feature and any future
/// Share/Action Extension targets need it.
///
/// Carries the prompt and the `MessagePart` attachments verbatim —
/// `MessagePart` is itself `Codable`, so the envelope round-trips images,
/// tool calls, and tool results without bespoke serialisation.
///
/// The `attachments` field decodes with a default-empty fallback so
/// envelopes written before the field existed still decode without
/// migration.
struct InboundPayloadEnvelope: Codable, Sendable {
    var prompt: String
    var attachments: [MessagePart]
    var source: String

    init(prompt: String, attachments: [MessagePart] = [], source: String) {
        self.prompt = prompt
        self.attachments = attachments
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, attachments, source
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.attachments = try container.decodeIfPresent([MessagePart].self, forKey: .attachments) ?? []
        self.source = try container.decode(String.self, forKey: .source)
    }
}

/// App Group identifier shared between a future inbound-handoff writer (an
/// App Intent) and the app's `.onOpenURL` handler (reader). Centralised so
/// renaming stays in one place.
///
/// The literal values here intentionally mirror ``ManifoldSharedAppGroup``
/// (in `PendingSharePayload.swift`). They're duplicated rather than
/// re-exported because a future Share/Action Extension target will compile
/// `PendingSharePayload.swift` alone — not the whole `Shared/` tree this
/// file lives in. If you rename either constant, update the other.
enum ManifoldAppGroup {
    static let identifier = "group.com.manifoldkit.apps"
    static let inboundKey = "manifold.inbound"
    static let pendingShareKey = "manifold.pending-share"
}

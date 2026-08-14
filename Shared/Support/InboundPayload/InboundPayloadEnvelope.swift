import Foundation
import ManifoldInference

/// JSON envelope written to App Group defaults by an App Intent and consumed
/// by the app's startup composition. Ported from ManifoldKit's own
/// `Example/Advanced/Intents/InboundPayloadEnvelope.swift` and kept in
/// `Shared/Support/` rather than a feature
/// directory because both the future AppIntents feature and any future
/// Share/Action Extension targets need it.
///
/// Carries the prompt and the `MessagePart` attachments verbatim —
/// `MessagePart` is itself `Codable`, so the envelope round-trips images,
/// tool calls, and tool results without bespoke serialisation.
///
/// The `attachments` field decodes with a default-empty fallback so
/// envelopes written before the field existed still decode without
/// migration. `handoffID` follows the same rule: each new write has a unique
/// compare-and-remove token, while legacy envelopes receive an ephemeral ID
/// when decoded. `createdAt` lets the handoff store prune abandoned payload
/// keys; legacy envelopes are conservatively treated as expired.
struct InboundPayloadEnvelope: Codable, Sendable {
    var prompt: String
    var attachments: [MessagePart]
    var source: String
    var handoffID: UUID
    var createdAt: Date

    init(
        prompt: String,
        attachments: [MessagePart] = [],
        source: String,
        handoffID: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.prompt = prompt
        self.attachments = attachments
        self.source = source
        self.handoffID = handoffID
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case prompt, attachments, source, handoffID, createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prompt = try container.decode(String.self, forKey: .prompt)
        self.attachments = try container.decodeIfPresent([MessagePart].self, forKey: .attachments) ?? []
        self.source = try container.decode(String.self, forKey: .source)
        self.handoffID = try container.decodeIfPresent(UUID.self, forKey: .handoffID) ?? UUID()
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }
}

/// App Group identifier shared between the AppIntent writer and startup
/// reader. Centralised so renaming stays in one place.
///
/// The literal values here intentionally mirror ``ManifoldSharedAppGroup``
/// (in `PendingSharePayload.swift`). They're duplicated rather than
/// re-exported because a future Share/Action Extension target will compile
/// `PendingSharePayload.swift` alone — not the whole `Shared/` tree this
/// file lives in. If you rename either constant, update the other.
enum ManifoldAppGroup {
    static let identifier = "group.com.manifoldkit.apps"
    /// Points to the most recently written inbound envelope ID. Its payload
    /// is stored under ``inboundPayloadKey(_:)`` so cleanup never has to
    /// compare-and-delete this shared pointer across processes.
    static let inboundKey = "manifold.inbound.pointer"
    /// Pre-token handoff slot used by the first AppIntents implementation.
    /// Readers consume it only when no current pointer exists.
    static let legacyInboundKey = "manifold.inbound"

    static func inboundPayloadKey(_ handoffID: UUID) -> String {
        "manifold.inbound.\(handoffID.uuidString)"
    }

    /// Marks a resolved current pointer. The bounded marker preserves
    /// single-slot last-wins semantics when that pointer later refers to its
    /// already-consumed or failed unique payload.
    static func inboundConsumedKey(_ handoffID: UUID) -> String {
        "manifold.inbound.consumed.\(handoffID.uuidString)"
    }

    static let pendingShareKey = "manifold.pending-share"
}

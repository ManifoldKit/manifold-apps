import Foundation
import ManifoldInference

/// The single App Group boundary shared by the AppIntent writer and app
/// startup reader. Keeping encode/write and take/decode here prevents the two
/// processes from quietly drifting onto different suites, keys, or formats.
/// A shared pointer records the latest handoff ID, while each envelope is
/// stored under its own key. This is intentionally last-pointer-wins: stale
/// payload keys are harmless and a failed writer can never delete the newer
/// pointer or payload.
enum InboundAppIntentEnvelopeStore {
    enum StoreError: Error {
        case appGroupUnavailable
    }

    enum TakeResult {
        case empty
        case payload(InboundPayload)
        case malformed(any Error)
        case appGroupUnavailable
    }

    /// Writes and returns the unique handoff ID stored in the envelope. The
    /// caller retains it as a compare-and-remove token if foregrounding the
    /// app fails; byte equality alone is not sufficient because two intents
    /// can legitimately carry identical content.
    @discardableResult
    static func write(_ envelope: InboundPayloadEnvelope) throws -> UUID {
        guard let defaults = UserDefaults(suiteName: ManifoldAppGroup.identifier) else {
            throw StoreError.appGroupUnavailable
        }
        let data = try JSONEncoder().encode(envelope)
        defaults.set(data, forKey: ManifoldAppGroup.inboundPayloadKey(envelope.handoffID))
        defaults.set(envelope.handoffID.uuidString, forKey: ManifoldAppGroup.inboundKey)
        return envelope.handoffID
    }

    /// Clears only the envelope written by the caller. If another invocation
    /// replaced the single slot while UIKit tried to open the route, its newer
    /// handoff must survive for that invocation.
    static func discardWrittenPayload(_ handoffID: UUID) {
        guard let defaults = UserDefaults(suiteName: ManifoldAppGroup.identifier) else { return }
        // Do not touch `inboundKey`: another process may already have pointed
        // it at a later envelope. Removing this unique payload key is safe
        // even if that replacement lands immediately before or after us.
        defaults.removeObject(forKey: ManifoldAppGroup.inboundPayloadKey(handoffID))
    }

    /// Consumes the latest pointer's unique envelope. Only that payload key is
    /// removed before decode; the pointer may remain stale after consumption,
    /// which is harmless and avoids a cross-process compare-and-remove race.
    static func take() -> TakeResult {
        guard let defaults = UserDefaults(suiteName: ManifoldAppGroup.identifier) else {
            return .appGroupUnavailable
        }

        if let rawHandoffID = defaults.string(forKey: ManifoldAppGroup.inboundKey),
           let handoffID = UUID(uuidString: rawHandoffID) {
            let payloadKey = ManifoldAppGroup.inboundPayloadKey(handoffID)
            guard let data = defaults.data(forKey: payloadKey) else { return .empty }
            defaults.removeObject(forKey: payloadKey)
            return decode(data)
        }

        // Upgrade path for envelopes written before unique payload keys and
        // the pointer existed. This legacy slot is no longer written.
        guard let legacyData = defaults.data(forKey: ManifoldAppGroup.legacyInboundKey) else {
            return .empty
        }
        defaults.removeObject(forKey: ManifoldAppGroup.legacyInboundKey)
        return decode(legacyData)
    }

    private static func decode(_ data: Data) -> TakeResult {
        do {
            let envelope = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data)
            return .payload(
                InboundPayload(
                    prompt: envelope.prompt,
                    attachments: envelope.attachments,
                    source: decodeSource(envelope.source)
                )
            )
        } catch {
            return .malformed(error)
        }
    }

    static func seedUITestEnvelopeIfRequested() {
        guard LaunchArguments.isUITesting,
              let defaults = UserDefaults(suiteName: ManifoldAppGroup.identifier) else {
            return
        }

        // Every UI test launch begins with an empty single-slot handoff so one
        // failed test cannot leak an envelope into the next test process.
        if let rawHandoffID = defaults.string(forKey: ManifoldAppGroup.inboundKey),
           let handoffID = UUID(uuidString: rawHandoffID) {
            defaults.removeObject(forKey: ManifoldAppGroup.inboundPayloadKey(handoffID))
        }
        defaults.removeObject(forKey: ManifoldAppGroup.inboundKey)
        defaults.removeObject(forKey: ManifoldAppGroup.legacyInboundKey)
        if LaunchArguments.seedsMalformedAppIntentEnvelope {
            let malformedID = UUID()
            defaults.set(Data("not-json".utf8), forKey: ManifoldAppGroup.inboundPayloadKey(malformedID))
            defaults.set(malformedID.uuidString, forKey: ManifoldAppGroup.inboundKey)
        } else if let prompt = LaunchArguments.appIntentPrompt {
            do {
                try write(InboundPayloadEnvelope(prompt: prompt, source: "appIntent"))
            } catch {
                Log.ui.error("UI test failed to seed AppIntent envelope: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private static func decodeSource(_ raw: String) -> InboundPayload.Source {
        switch raw {
        case "deepLink": return .deepLink
        case "shareExtension": return .shareExtension
        case "appIntent": return .appIntent
        default:
            Log.ui.warning("AppIntentsFeature: unknown inbound source '\(raw, privacy: .public)' — defaulting to .appIntent")
            return .appIntent
        }
    }
}

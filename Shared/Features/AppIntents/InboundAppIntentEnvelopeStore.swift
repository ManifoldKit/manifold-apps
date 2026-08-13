import Foundation
import ManifoldInference

/// The single App Group boundary shared by the AppIntent writer and app
/// startup reader. Keeping encode/write and take/decode here prevents the two
/// processes from quietly drifting onto different suites, keys, or formats.
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

    static func write(_ envelope: InboundPayloadEnvelope) throws {
        guard let defaults = UserDefaults(suiteName: ManifoldAppGroup.identifier) else {
            throw StoreError.appGroupUnavailable
        }
        defaults.set(try JSONEncoder().encode(envelope), forKey: ManifoldAppGroup.inboundKey)
    }

    /// Consumes the single-slot envelope: the key is removed before decode so
    /// malformed data cannot replay forever on every launch.
    static func take() -> TakeResult {
        guard let defaults = UserDefaults(suiteName: ManifoldAppGroup.identifier) else {
            return .appGroupUnavailable
        }
        guard let data = defaults.data(forKey: ManifoldAppGroup.inboundKey) else {
            return .empty
        }
        defaults.removeObject(forKey: ManifoldAppGroup.inboundKey)

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
        defaults.removeObject(forKey: ManifoldAppGroup.inboundKey)
        if LaunchArguments.seedsMalformedAppIntentEnvelope {
            defaults.set(Data("not-json".utf8), forKey: ManifoldAppGroup.inboundKey)
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

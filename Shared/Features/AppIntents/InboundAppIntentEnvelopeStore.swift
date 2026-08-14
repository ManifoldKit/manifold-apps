import Foundation
import ManifoldInference

/// The single App Group boundary shared by the AppIntent writer and app
/// startup reader. Keeping encode/write and take/decode here prevents the two
/// processes from quietly drifting onto different suites, keys, or formats.
/// A shared pointer records the latest handoff ID, while each envelope is
/// stored under its own key. A bounded consumed-current marker preserves the
/// intentional last-pointer-wins behavior after a successful take, while a
/// failed writer (which never creates that marker) may still recover the
/// earlier payload it masked.
enum InboundAppIntentEnvelopeStore {
    /// An App Intent handoff is transient. This caps recovery of orphaned
    /// unique payload keys left by a terminated/failed writer.
    static let maximumEnvelopeAge: TimeInterval = 5 * 60

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
        return try write(envelope, to: defaults)
    }

    @discardableResult
    static func write(_ envelope: InboundPayloadEnvelope, to defaults: UserDefaults) throws -> UUID {
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
        discardWrittenPayload(handoffID, from: defaults)
    }

    static func discardWrittenPayload(_ handoffID: UUID, from defaults: UserDefaults) {
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
        return take(from: defaults, now: Date(), maximumAge: maximumEnvelopeAge)
    }

    /// The injectable form keeps expiry and pointer-loss recovery directly
    /// testable without changing the production App Group contract.
    static func take(
        from defaults: UserDefaults,
        now: Date,
        maximumAge: TimeInterval
    ) -> TakeResult {
        pruneExpiredTombstones(from: defaults, now: now, maximumAge: maximumAge)
        var suppressCandidatesAtOrBefore: Date?
        var stalePointerHandoffID: UUID?
        if let rawHandoffID = defaults.string(forKey: ManifoldAppGroup.inboundKey),
           let handoffID = UUID(uuidString: rawHandoffID) {
            let payloadKey = ManifoldAppGroup.inboundPayloadKey(handoffID)
            if let data = defaults.data(forKey: payloadKey) {
                defaults.removeObject(forKey: payloadKey)
                let currentResult = decode(data, now: now, maximumAge: maximumAge) { envelope in
                    markCurrentConsumed(envelope, in: defaults)
                }
                switch currentResult {
                case .payload, .malformed:
                    // Preserve malformed-current reporting; only missing or
                    // expired current payloads may recover an older orphan.
                    return currentResult
                case .empty, .appGroupUnavailable:
                    stalePointerHandoffID = handoffID
                    break
                }
            } else {
                if let consumedAt = takeConsumedMarker(
                    for: handoffID,
                    from: defaults,
                    now: now,
                    maximumAge: maximumAge
                ) {
                    // A successfully delivered B must not later expose an
                    // older A merely because the stable pointer still names B.
                    suppressCandidatesAtOrBefore = consumedAt
                } else {
                    stalePointerHandoffID = handoffID
                }
            }
        }

        if let recovered = takeNewestFreshCandidate(
            from: defaults,
            now: now,
            maximumAge: maximumAge,
            suppressingAtOrBefore: suppressCandidatesAtOrBefore
        ) {
            if let stalePointerHandoffID {
                // A failed/expired B that falls back to A has now resolved
                // the single-slot timeline through A. Use A's timestamp, not
                // `now`, so a concurrent newer C remains eligible.
                markPointerResolved(
                    stalePointerHandoffID,
                    at: recovered.createdAt,
                    in: defaults
                )
            }
            return payloadResult(for: recovered)
        }

        // Upgrade path for envelopes written before unique payload keys and
        // the pointer existed. This legacy slot is no longer written.
        guard let legacyData = defaults.data(forKey: ManifoldAppGroup.legacyInboundKey) else {
            return .empty
        }
        defaults.removeObject(forKey: ManifoldAppGroup.legacyInboundKey)
        // The raw legacy slot is consumed exactly once before decode, so it
        // cannot replay. Preserve this documented upgrade path even though
        // pre-`createdAt` envelopes otherwise look expired as orphan keys.
        return decodeLegacyRawSlot(legacyData)
    }

    private static func decode(
        _ data: Data,
        now: Date,
        maximumAge: TimeInterval,
        onFreshEnvelope: (InboundPayloadEnvelope) -> Void = { _ in }
    ) -> TakeResult {
        do {
            let envelope = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data)
            guard isFresh(envelope, now: now, maximumAge: maximumAge) else {
                return .empty
            }
            onFreshEnvelope(envelope)
            return payloadResult(for: envelope)
        } catch {
            return .malformed(error)
        }
    }

    private static func decodeLegacyRawSlot(_ data: Data) -> TakeResult {
        do {
            return payloadResult(for: try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data))
        } catch {
            return .malformed(error)
        }
    }

    private static func payloadResult(for envelope: InboundPayloadEnvelope) -> TakeResult {
        .payload(
            InboundPayload(
                prompt: envelope.prompt,
                attachments: envelope.attachments,
                source: decodeSource(envelope.source)
            )
        )
    }

    /// Scans only unique payload keys after the current pointer is absent,
    /// invalid, or points to a missing/expired payload. The newest fresh
    /// envelope is consumed first; remaining fresh keys can recover from a
    /// later writer whose route open failed. Expired and malformed orphans
    /// are pruned and can never execute later.
    private static func takeNewestFreshCandidate(
        from defaults: UserDefaults,
        now: Date,
        maximumAge: TimeInterval,
        suppressingAtOrBefore: Date?
    ) -> InboundPayloadEnvelope? {
        var candidates: [(key: String, envelope: InboundPayloadEnvelope)] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            guard let handoffID = handoffID(forPayloadKey: key),
                  let data = value as? Data else {
                continue
            }
            do {
                let envelope = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data)
                guard envelope.handoffID == handoffID else {
                    defaults.removeObject(forKey: key)
                    Log.ui.warning("AppIntentsFeature: discarded inbound payload with mismatched handoff ID")
                    continue
                }
                guard isFresh(envelope, now: now, maximumAge: maximumAge) else {
                    defaults.removeObject(forKey: key)
                    continue
                }
                if let suppressingAtOrBefore,
                   envelope.createdAt <= suppressingAtOrBefore {
                    defaults.removeObject(forKey: key)
                    continue
                }
                candidates.append((key, envelope))
            } catch {
                defaults.removeObject(forKey: key)
                Log.ui.warning("AppIntentsFeature: discarded malformed orphaned inbound envelope: \(String(describing: error), privacy: .public)")
            }
        }

        guard let newest = candidates.max(by: { $0.envelope.createdAt < $1.envelope.createdAt }) else {
            return nil
        }
        defaults.removeObject(forKey: newest.key)
        return newest.envelope
    }

    private static func markCurrentConsumed(
        _ envelope: InboundPayloadEnvelope,
        in defaults: UserDefaults
    ) {
        markPointerResolved(envelope.handoffID, at: envelope.createdAt, in: defaults)
    }

    private static func markPointerResolved(
        _ handoffID: UUID,
        at createdAt: Date,
        in defaults: UserDefaults
    ) {
        defaults.set(
            createdAt.timeIntervalSinceReferenceDate,
            forKey: ManifoldAppGroup.inboundConsumedKey(handoffID)
        )
    }

    private static func takeConsumedMarker(
        for handoffID: UUID,
        from defaults: UserDefaults,
        now: Date,
        maximumAge: TimeInterval
    ) -> Date? {
        let key = ManifoldAppGroup.inboundConsumedKey(handoffID)
        guard let timestamp = defaults.object(forKey: key) as? Double else { return nil }
        let consumedAt = Date(timeIntervalSinceReferenceDate: timestamp)
        defaults.removeObject(forKey: key)
        guard now.timeIntervalSince(consumedAt) <= maximumAge else { return nil }
        return consumedAt
    }

    private static func pruneExpiredTombstones(
        from defaults: UserDefaults,
        now: Date,
        maximumAge: TimeInterval
    ) {
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix("\(ManifoldAppGroup.legacyInboundKey).consumed."),
                  let timestamp = value as? Double else {
                continue
            }
            let consumedAt = Date(timeIntervalSinceReferenceDate: timestamp)
            if now.timeIntervalSince(consumedAt) > maximumAge {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private static func handoffID(forPayloadKey key: String) -> UUID? {
        guard key.hasPrefix("\(ManifoldAppGroup.legacyInboundKey).") else { return nil }
        let suffix = String(key.dropFirst(ManifoldAppGroup.legacyInboundKey.count + 1))
        return UUID(uuidString: suffix)
    }

    private static func isFresh(
        _ envelope: InboundPayloadEnvelope,
        now: Date,
        maximumAge: TimeInterval
    ) -> Bool {
        envelope.createdAt <= now && now.timeIntervalSince(envelope.createdAt) <= maximumAge
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
            defaults.removeObject(forKey: ManifoldAppGroup.inboundConsumedKey(handoffID))
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

import XCTest
import ManifoldInference

/// AppIntents feature coverage: the real App Group envelope wire contract,
/// plus UI-level assertions that the feature renders its live content and
/// registers `SetReminderIntent` into the chat runtime's actual registry.
final class AppIntentsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Real envelope wire format

    func test_envelope_roundTripsPromptAndSource() throws {
        let envelope = InboundPayloadEnvelope(prompt: "summarize this article", attachments: [], source: "appIntent")

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data)

        XCTAssertEqual(decoded.prompt, "summarize this article")
        XCTAssertEqual(decoded.source, "appIntent")
        XCTAssertTrue(decoded.attachments.isEmpty)
        XCTAssertEqual(decoded.handoffID, envelope.handoffID)
        XCTAssertEqual(decoded.createdAt, envelope.createdAt)
    }

    func test_envelope_roundTripsAttachmentsEndToEnd() throws {
        let attachments: [MessagePart] = [
            .text("relevant context"),
            .image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png"),
            .thinking("model reasoning carried verbatim", signature: "sig-abc"),
        ]
        let envelope = InboundPayloadEnvelope(prompt: "act on the attached payload", attachments: attachments, source: "shareExtension")

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: data)

        XCTAssertEqual(decoded.prompt, "act on the attached payload")
        XCTAssertEqual(decoded.source, "shareExtension")
        XCTAssertEqual(decoded.attachments, attachments)
        XCTAssertEqual(decoded.handoffID, envelope.handoffID)
        XCTAssertEqual(decoded.createdAt, envelope.createdAt)
    }

    func test_envelope_decodesLegacyShapeWithoutAttachmentsField() throws {
        // A payload written before `attachments` existed must still decode
        // rather than throwing on a missing key.
        let legacyJSON = #"{"prompt":"hello","source":"appIntent"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: legacyJSON)

        XCTAssertEqual(decoded.prompt, "hello")
        XCTAssertEqual(decoded.source, "appIntent")
        XCTAssertTrue(decoded.attachments.isEmpty)
        // Legacy envelopes did not carry a compare-and-remove token. Decoding
        // still succeeds and assigns one for the in-process representation.
        // Its unknown creation time is conservatively expired so a stale
        // orphan cannot execute after an upgrade.
        XCTAssertFalse(decoded.handoffID.uuidString.isEmpty)
        XCTAssertEqual(decoded.createdAt, .distantPast)
    }

    func test_envelope_emitsAttachmentsKeyWhenNonEmpty() throws {
        // Pins the wire format: a non-empty `attachments` array must
        // serialise under the literal key `"attachments"` so
        // `InboundAppIntentEnvelopeStore.take()` (and any future
        // out-of-process consumer) can find it.
        let envelope = InboundPayloadEnvelope(prompt: "p", attachments: [.text("a")], source: "appIntent")

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(object?["attachments"])
        XCTAssertEqual((object?["attachments"] as? [Any])?.count, 1)
        XCTAssertEqual(object?["handoffID"] as? String, envelope.handoffID.uuidString)
        XCTAssertNotNil(object?["createdAt"])
    }

    // MARK: - App Group pointer recovery

    func test_envelopeStore_failedLaterWriterDoesNotMaskEarlierPayload() throws {
        guard let defaults = makeIsolatedEnvelopeDefaults() else {
            XCTFail("An isolated UserDefaults suite is required for the handoff store test")
            return
        }
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let earlier = InboundPayloadEnvelope(prompt: "A", source: "appIntent", createdAt: now.addingTimeInterval(-1))
        let failedLater = InboundPayloadEnvelope(prompt: "B", source: "appIntent", createdAt: now)
        try InboundAppIntentEnvelopeStore.write(earlier, to: defaults)
        try InboundAppIntentEnvelopeStore.write(failedLater, to: defaults)
        InboundAppIntentEnvelopeStore.discardWrittenPayload(failedLater.handoffID, from: defaults)

        let result = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        XCTAssertEqual(prompt(in: result), "A")
    }

    func test_envelopeStore_failedWriterFallbackSuppressesOlderHistory() throws {
        guard let defaults = makeIsolatedEnvelopeDefaults() else {
            XCTFail("An isolated UserDefaults suite is required for the handoff store test")
            return
        }
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let oldest = InboundPayloadEnvelope(prompt: "O", source: "appIntent", createdAt: now.addingTimeInterval(-3))
        let recovered = InboundPayloadEnvelope(prompt: "A", source: "appIntent", createdAt: now.addingTimeInterval(-2))
        let failedLater = InboundPayloadEnvelope(prompt: "B", source: "appIntent", createdAt: now.addingTimeInterval(-1))
        try InboundAppIntentEnvelopeStore.write(oldest, to: defaults)
        try InboundAppIntentEnvelopeStore.write(recovered, to: defaults)
        try InboundAppIntentEnvelopeStore.write(failedLater, to: defaults)
        InboundAppIntentEnvelopeStore.discardWrittenPayload(failedLater.handoffID, from: defaults)

        let first = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        let second = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )

        XCTAssertEqual(prompt(in: first), "A")
        XCTAssertNil(prompt(in: second), "Fallback must resolve B through A instead of replaying older O")
        XCTAssertNil(defaults.data(forKey: ManifoldAppGroup.inboundPayloadKey(oldest.handoffID)))
    }

    func test_envelopeStore_failedWriterFallbackLeavesNewerCandidateEligible() throws {
        guard let defaults = makeIsolatedEnvelopeDefaults() else {
            XCTFail("An isolated UserDefaults suite is required for the handoff store test")
            return
        }
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let oldest = InboundPayloadEnvelope(prompt: "O", source: "appIntent", createdAt: now.addingTimeInterval(-3))
        let recovered = InboundPayloadEnvelope(prompt: "A", source: "appIntent", createdAt: now.addingTimeInterval(-2))
        let failedLater = InboundPayloadEnvelope(prompt: "B", source: "appIntent", createdAt: now.addingTimeInterval(-1))
        try InboundAppIntentEnvelopeStore.write(oldest, to: defaults)
        try InboundAppIntentEnvelopeStore.write(recovered, to: defaults)
        try InboundAppIntentEnvelopeStore.write(failedLater, to: defaults)
        InboundAppIntentEnvelopeStore.discardWrittenPayload(failedLater.handoffID, from: defaults)

        let first = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        XCTAssertEqual(prompt(in: first), "A")

        // Simulates C landing after the failed B route but before the next
        // app read. It deliberately does not replace B's stale pointer.
        let newer = InboundPayloadEnvelope(prompt: "C", source: "appIntent", createdAt: now)
        defaults.set(
            try JSONEncoder().encode(newer),
            forKey: ManifoldAppGroup.inboundPayloadKey(newer.handoffID)
        )
        let second = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )

        XCTAssertEqual(prompt(in: second), "C", "A fallback tombstone must not suppress later C")
        XCTAssertNil(defaults.data(forKey: ManifoldAppGroup.inboundPayloadKey(oldest.handoffID)))
    }

    func test_envelopeStore_takesCurrentThenSuppressesEarlierPayload() throws {
        guard let defaults = makeIsolatedEnvelopeDefaults() else {
            XCTFail("An isolated UserDefaults suite is required for the handoff store test")
            return
        }
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let earlier = InboundPayloadEnvelope(prompt: "A", source: "appIntent", createdAt: now.addingTimeInterval(-2))
        let current = InboundPayloadEnvelope(prompt: "B", source: "appIntent", createdAt: now.addingTimeInterval(-1))
        try InboundAppIntentEnvelopeStore.write(earlier, to: defaults)
        try InboundAppIntentEnvelopeStore.write(current, to: defaults)

        let first = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        let second = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        XCTAssertEqual(prompt(in: first), "B")
        XCTAssertNil(prompt(in: second), "A successful current B preserves single-slot last-wins semantics")
        XCTAssertNil(defaults.data(forKey: ManifoldAppGroup.inboundPayloadKey(earlier.handoffID)))
        XCTAssertNil(defaults.object(forKey: ManifoldAppGroup.inboundConsumedKey(current.handoffID)))
    }

    func test_envelopeStore_prunesExpiredOrphanWithoutDeliveringIt() throws {
        guard let defaults = makeIsolatedEnvelopeDefaults() else {
            XCTFail("An isolated UserDefaults suite is required for the handoff store test")
            return
        }
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let expired = InboundPayloadEnvelope(
            prompt: "expired",
            source: "appIntent",
            createdAt: now.addingTimeInterval(-InboundAppIntentEnvelopeStore.maximumEnvelopeAge - 1)
        )
        try InboundAppIntentEnvelopeStore.write(expired, to: defaults)

        let result = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        XCTAssertNil(prompt(in: result))
        XCTAssertNil(defaults.data(forKey: ManifoldAppGroup.inboundPayloadKey(expired.handoffID)))
    }

    func test_envelopeStore_reportsMalformedCurrentPointer() {
        guard let defaults = makeIsolatedEnvelopeDefaults() else {
            XCTFail("An isolated UserDefaults suite is required for the handoff store test")
            return
        }
        let handoffID = UUID()
        defaults.set(Data("not-json".utf8), forKey: ManifoldAppGroup.inboundPayloadKey(handoffID))
        defaults.set(handoffID.uuidString, forKey: ManifoldAppGroup.inboundKey)

        let result = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: Date(timeIntervalSinceReferenceDate: 1_000_000),
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        guard case .malformed = result else {
            XCTFail("Malformed current pointer payload must remain visibly reported")
            return
        }
    }

    func test_envelopeStore_consumesLegacyRawSlotOnceWithoutOrphanExpiry() {
        guard let defaults = makeIsolatedEnvelopeDefaults() else {
            XCTFail("An isolated UserDefaults suite is required for the handoff store test")
            return
        }
        defaults.set(
            Data(#"{"prompt":"legacy","source":"appIntent"}"#.utf8),
            forKey: ManifoldAppGroup.legacyInboundKey
        )

        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let first = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        let second = InboundAppIntentEnvelopeStore.take(
            from: defaults,
            now: now,
            maximumAge: InboundAppIntentEnvelopeStore.maximumEnvelopeAge
        )
        XCTAssertEqual(prompt(in: first), "legacy")
        XCTAssertNil(prompt(in: second))
    }

    // MARK: - Readiness-aware delivery

    @MainActor
    func test_pendingPayload_waitsForReadyThenDrainsExactlyOnce() async {
        let buffer = PendingPayloadBuffer()
        let payload = InboundPayload(prompt: "deliver after load", source: .appIntent)
        let generation = await buffer.store(payload)

        let (updates, continuation) = AsyncStream<ModelLoadReadinessState>.makeStream()
        let recorder = PayloadRecorder()
        let delivery = Task {
            await buffer.deliverWhenModelReady(generation: generation, readinessUpdates: updates) { inbound in
                recorder.record(inbound)
                return true
            }
        }

        continuation.yield(.idle)
        continuation.yield(.loading(progress: 0.5))
        await waitForDeliveryState(.waitingForModel, in: buffer)

        let retainedWhileLoading = await buffer.peek()
        XCTAssertEqual(retainedWhileLoading?.prompt, "deliver after load")
        XCTAssertTrue(recorder.payloads.isEmpty, "Loading is not readiness; ingest must not race the model load")

        continuation.yield(.ready)
        continuation.finish()
        await delivery.value

        let drainedAfterReady = await buffer.peek()
        let finalState = await buffer.currentDeliveryState()
        XCTAssertNil(drainedAfterReady)
        XCTAssertEqual(finalState, .delivered)
        XCTAssertEqual(recorder.payloads.map(\.prompt), ["deliver after load"])
    }

    @MainActor
    func test_pendingPayload_streamEndingBeforeReadyRetainsPayloadAndReportsDegradedState() async {
        let buffer = PendingPayloadBuffer()
        let generation = await buffer.store(InboundPayload(prompt: "keep me", source: .appIntent))
        let recorder = PayloadRecorder()
        let updates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.idle)
            continuation.yield(.loading(progress: 0.25))
            continuation.finish()
        }

        await buffer.deliverWhenModelReady(generation: generation, readinessUpdates: updates) { inbound in
            recorder.record(inbound)
            return true
        }

        let retained = await buffer.peek()
        let finalState = await buffer.currentDeliveryState()
        XCTAssertEqual(retained?.prompt, "keep me")
        XCTAssertEqual(finalState, .readinessStreamEnded)
        XCTAssertTrue(recorder.payloads.isEmpty, "A readiness stream ending early must not silently consume the payload")
    }

    /// Mirrors the warm scene contract without needing a system AppIntent
    /// invocation in the UI-test runner: a valid `manifold://ingest` event
    /// stages into the same single-slot buffer, then waits for `.ready` before
    /// delivery. Sabotage rationale: changing the route predicate to accept a
    /// different host or removing the readiness buffer makes one of the route
    /// / pre-ready assertions below fail, rather than merely exercising a
    /// cold-launch-only path.
    @MainActor
    func test_warmInboundURL_stagesThenDeliversOnlyAfterReady() async {
        XCTAssertTrue(InboundAppIntentRoute.isInboundURL(URL(string: "manifold://ingest")!))
        XCTAssertFalse(InboundAppIntentRoute.isInboundURL(URL(string: "manifold://other")!))
        XCTAssertFalse(InboundAppIntentRoute.isInboundURL(URL(string: "other://ingest")!))
        XCTAssertFalse(InboundAppIntentRoute.isInboundURL(URL(string: "manifold://ingest/unexpected")!))

        let buffer = PendingPayloadBuffer()
        let recorder = PayloadRecorder()
        let generation = await buffer.store(InboundPayload(prompt: "warm scene payload", source: .appIntent))
        let (updates, continuation) = AsyncStream<ModelLoadReadinessState>.makeStream()
        let delivery = Task {
            await buffer.deliverWhenModelReady(generation: generation, readinessUpdates: updates) { inbound in
                recorder.record(inbound)
                return true
            }
        }

        continuation.yield(.loading(progress: 0.75))
        await waitForDeliveryState(.waitingForModel, in: buffer)
        XCTAssertTrue(recorder.payloads.isEmpty, "A warm URL handoff must not ingest before the model is ready")

        continuation.yield(.ready)
        continuation.finish()
        await delivery.value
        XCTAssertEqual(recorder.payloads.map(\.prompt), ["warm scene payload"])
    }

    /// A warm URL can replace the pending payload between its store and the
    /// predecessor task's cancellation. The older task must not drain that
    /// newer slot merely because it observed `.ready` first. Sabotage
    /// rationale: removing the generation equality check immediately before
    /// `drain()` makes the predecessor deliver "newer warm payload" and this
    /// test fail.
    @MainActor
    func test_pendingPayload_replacementDoesNotLetOlderDeliveryDrainNewerPayload() async {
        let buffer = PendingPayloadBuffer()
        let recorder = PayloadRecorder()
        let firstGeneration = await buffer.store(InboundPayload(prompt: "first warm payload", source: .appIntent))
        let (firstUpdates, firstContinuation) = AsyncStream<ModelLoadReadinessState>.makeStream()
        let firstDelivery = Task {
            await buffer.deliverWhenModelReady(generation: firstGeneration, readinessUpdates: firstUpdates) { inbound in
                recorder.record(inbound)
                return true
            }
        }

        firstContinuation.yield(.loading(progress: 0.5))
        await waitForDeliveryState(.waitingForModel, in: buffer)

        let newerGeneration = await buffer.store(InboundPayload(prompt: "newer warm payload", source: .appIntent))
        firstContinuation.yield(.ready)
        firstContinuation.finish()
        await firstDelivery.value

        XCTAssertTrue(recorder.payloads.isEmpty, "A predecessor must not consume the replacement payload")
        let retainedReplacement = await buffer.peek()
        XCTAssertEqual(retainedReplacement?.prompt, "newer warm payload")

        let readyUpdates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        await buffer.deliverWhenModelReady(generation: newerGeneration, readinessUpdates: readyUpdates) { inbound in
            recorder.record(inbound)
            return true
        }
        XCTAssertEqual(recorder.payloads.map(\.prompt), ["newer warm payload"])
    }

    /// The bootstrap installation can reach `.ready` just before RootView's
    /// feature loop replaces it. If cancellation wins before `ingest`
    /// acknowledges, the cold-start payload must remain for that replacement
    /// task. Sabotage rationale: draining before the closure returns (the old
    /// implementation) leaves `peek()` nil and makes this regression fail.
    @MainActor
    func test_pendingPayload_cancellationAfterReadyBeforeAcknowledgementRetainsPayload() async {
        let buffer = PendingPayloadBuffer()
        let payload = InboundPayload(prompt: "retain after canceled ready delivery", source: .appIntent)
        let generation = await buffer.store(payload)
        let acknowledgement = DeliveryAcknowledgementProbe()
        let recorder = PayloadRecorder()
        let updates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        let canceledDelivery = Task {
            await buffer.deliverWhenModelReady(generation: generation, readinessUpdates: updates) { inbound in
                await acknowledgement.waitForRelease()
                guard !Task.isCancelled else { return false }
                recorder.record(inbound)
                return true
            }
        }

        await acknowledgement.waitUntilWaiting()
        canceledDelivery.cancel()
        await acknowledgement.release()
        await canceledDelivery.value

        let retained = await buffer.peek()
        let state = await buffer.currentDeliveryState()
        XCTAssertEqual(retained?.prompt, payload.prompt)
        XCTAssertEqual(state, .deliveryUnacknowledged)
        XCTAssertTrue(recorder.payloads.isEmpty, "A canceled pre-acknowledgement closure must not claim ingestion")

        let retryUpdates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        await buffer.deliverWhenModelReady(generation: generation, readinessUpdates: retryUpdates) { inbound in
            recorder.record(inbound)
            return true
        }
        let drainedAfterRetry = await buffer.peek()
        XCTAssertNil(drainedAfterRetry)
        XCTAssertEqual(recorder.payloads.map(\.prompt), [payload.prompt])
    }

    /// A delivery closure can suspend in `ingest` while a newer warm route
    /// replaces the single slot. Even if the predecessor subsequently
    /// acknowledges its own ingest, only that old turn completed; it may not
    /// drain the newer payload.
    @MainActor
    func test_pendingPayload_acknowledgementAfterReplacementPreservesNewerGeneration() async {
        let buffer = PendingPayloadBuffer()
        let recorder = PayloadRecorder()
        let firstGeneration = await buffer.store(InboundPayload(prompt: "first", source: .appIntent))
        let acknowledgement = DeliveryAcknowledgementProbe()
        let updates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        let firstDelivery = Task {
            await buffer.deliverWhenModelReady(generation: firstGeneration, readinessUpdates: updates) { inbound in
                await acknowledgement.waitForRelease()
                recorder.record(inbound)
                return true
            }
        }

        await acknowledgement.waitUntilWaiting()
        let newerGeneration = await buffer.store(InboundPayload(prompt: "newer", source: .appIntent))
        await acknowledgement.release()
        await firstDelivery.value

        let retainedNewer = await buffer.peek()
        XCTAssertEqual(retainedNewer?.prompt, "newer")
        let retryUpdates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        await buffer.deliverWhenModelReady(generation: newerGeneration, readinessUpdates: retryUpdates) { inbound in
            recorder.record(inbound)
            return true
        }
        XCTAssertEqual(recorder.payloads.map(\.prompt), ["first", "newer"])
    }

    /// `deliverWhenModelReady` awaits the acknowledgement closure, so the
    /// actor is re-entrant while `ingest` is running. A generation claim must
    /// prevent a second same-generation install from entering another closure
    /// during that window.
    @MainActor
    func test_pendingPayload_sameGenerationAllowsOnlyOneAcknowledgedDelivery() async {
        let buffer = PendingPayloadBuffer()
        let generation = await buffer.store(InboundPayload(prompt: "once", source: .appIntent))
        let acknowledgement = DeliveryAcknowledgementProbe()
        let recorder = PayloadRecorder()
        let firstUpdates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        let firstDelivery = Task {
            await buffer.deliverWhenModelReady(generation: generation, readinessUpdates: firstUpdates) { inbound in
                await acknowledgement.waitForRelease()
                recorder.record(inbound)
                return true
            }
        }

        await acknowledgement.waitUntilWaiting()
        let secondUpdates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
        await buffer.deliverWhenModelReady(generation: generation, readinessUpdates: secondUpdates) { inbound in
            recorder.record(inbound)
            return true
        }
        XCTAssertTrue(recorder.payloads.isEmpty, "A duplicate same-generation task must not enter its delivery closure")

        await acknowledgement.release()
        await firstDelivery.value
        XCTAssertEqual(recorder.payloads.map(\.prompt), ["once"])
    }

    func test_backgroundReadinessGate_waitsBeforeGenerating() async throws {
        let probe = ReadinessGateProbe()
        let task = Task {
            try await AppIntentModelReadinessGate.executeWhenReady(
                waitForReadiness: { await probe.waitForReady() },
                work: {
                    await probe.recordGeneration()
                    return "reply"
                }
            )
        }

        await probe.waitUntilWaiting()
        let generatedBeforeReady = await probe.didGenerate
        XCTAssertFalse(generatedBeforeReady, "Inference must not start before the background readiness gate opens")

        await probe.markReady()
        let reply = try await task.value
        let generatedAfterReady = await probe.didGenerate
        XCTAssertEqual(reply, "reply")
        XCTAssertTrue(generatedAfterReady)
    }

    func test_backgroundReadinessGate_reportsUnavailableStreamWithoutGenerating() async {
        let updates = AsyncStream<ModelLoadReadinessState> { $0.finish() }
        let probe = ReadinessGateProbe()

        do {
            _ = try await AppIntentModelReadinessGate.executeWhenReady(
                waitForReadiness: { try await AppIntentModelReadinessGate.waitUntilReady(updates) },
                work: {
                    await probe.recordGeneration()
                    return "unreachable"
                }
            )
            XCTFail("A readiness stream that ends before .ready must report a failure")
        } catch let error as AppIntentModelReadinessGate.Error {
            XCTAssertEqual(error, .modelUnavailable)
        } catch {
            XCTFail("Expected the explicit readiness failure, got \(error)")
        }
        let generatedAfterFailure = await probe.didGenerate
        XCTAssertFalse(generatedAfterFailure, "The red readiness path must not invoke inference")
    }

    func test_backgroundReadinessGate_failsImmediatelyWhenModelIsIdle() async {
        let updates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.idle)
        }
        let probe = ReadinessGateProbe()

        do {
            _ = try await AppIntentModelReadinessGate.executeWhenReady(
                waitForReadiness: {
                    try await AppIntentModelReadinessGate.waitUntilReady(
                        updates,
                        maxPollCount: 10,
                        pollIntervalNanoseconds: 1_000_000
                    )
                },
                work: {
                    await probe.recordGeneration()
                    return "unreachable"
                }
            )
            XCTFail("An idle model must fail without waiting for a future load")
        } catch let error as AppIntentModelReadinessGate.Error {
            XCTAssertEqual(error, .modelUnavailable)
        } catch {
            XCTFail("Expected model-unavailable failure, got \(error)")
        }
        let generatedAfterIdle = await probe.didGenerate
        XCTAssertFalse(generatedAfterIdle)
    }

    func test_backgroundReadinessGate_timesOutLoadingWithoutGenerating() async {
        let updates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.loading(progress: 0.1))
        }
        let probe = ReadinessGateProbe()

        do {
            _ = try await AppIntentModelReadinessGate.executeWhenReady(
                waitForReadiness: {
                    try await AppIntentModelReadinessGate.waitUntilReady(
                        updates,
                        maxPollCount: 1,
                        pollIntervalNanoseconds: 1_000_000
                    )
                },
                work: {
                    await probe.recordGeneration()
                    return "unreachable"
                }
            )
            XCTFail("A loading model that never reaches ready must time out")
        } catch let error as AppIntentModelReadinessGate.Error {
            XCTAssertEqual(error, .modelUnavailable)
        } catch {
            XCTFail("Expected bounded model-unavailable failure, got \(error)")
        }
        let generatedAfterTimeout = await probe.didGenerate
        XCTAssertFalse(generatedAfterTimeout)
    }

    func test_backgroundReadinessGate_cancellationDoesNotGenerate() async {
        let updates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.loading(progress: 0.1))
        }
        let probe = ReadinessGateProbe()
        let task = Task {
            try await AppIntentModelReadinessGate.executeWhenReady(
                waitForReadiness: {
                    try await AppIntentModelReadinessGate.waitUntilReady(
                        updates,
                        maxPollCount: 600,
                        pollIntervalNanoseconds: 50_000_000
                    )
                },
                work: {
                    await probe.recordGeneration()
                    return "unreachable"
                }
            )
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must escape the readiness gate")
        } catch is CancellationError {
            // Expected: cancellation is not translated into an inference attempt.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let generatedAfterCancellation = await probe.didGenerate
        XCTAssertFalse(generatedAfterCancellation)
    }

    /// Covers the degraded route-open result without touching real App Group
    /// defaults or UIKit. A later writer can replace the slot with identical
    /// JSON content while `open` is in flight; the failed predecessor may
    /// clear only its own unique handoff ID.
    @MainActor
    func test_failedWarmRouteOpenClearsOnlyTheEnvelopeItWrote() async {
        let failedStorage = HandoffStorageProbe()
        let failedEnvelope = UUID()
        do {
            try await InboundAppIntentHandoff.writeAndOpen(
                write: { failedStorage.write(failedEnvelope) },
                discardWrittenPayload: { failedStorage.discardWrittenPayload($0) },
                open: { false }
            )
            XCTFail("A failed route open must report the degraded handoff")
        } catch let error as InboundAppIntentHandoff.Error {
            XCTAssertEqual(error, .failedToOpenRoute)
        } catch {
            XCTFail("Expected typed route-open failure, got \(error)")
        }
        XCTAssertNil(failedStorage.current, "A failed route open must not leave its payload for a later launch")

        let storage = HandoffStorageProbe()
        let identicalPayload = Data("{\"prompt\":\"same\"}".utf8)
        let written = UUID()
        let replacement = UUID()

        do {
            try await InboundAppIntentHandoff.writeAndOpen(
                write: { storage.write(payload: identicalPayload, handoffID: written) },
                discardWrittenPayload: { storage.discardWrittenPayload($0) },
                open: {
                    storage.write(payload: identicalPayload, handoffID: replacement)
                    return false
                }
            )
            XCTFail("A failed replacement route open must report the degraded handoff")
        } catch let error as InboundAppIntentHandoff.Error {
            XCTAssertEqual(error, .failedToOpenRoute)
        } catch {
            XCTFail("Expected typed route-open failure, got \(error)")
        }

        XCTAssertFalse(storage.contains(written), "Failed-open cleanup should remove only the predecessor's unique payload")
        XCTAssertEqual(storage.current?.handoffID, replacement, "Failure cleanup must not erase an identical-content newer invocation")
    }

    // MARK: - UI-level: sidebar renders AppIntentsFeature's real content

    /// Fails if `AppIntentsFeature.makeView(env:)` reverts to
    /// `NotYetPortedView` (or any other placeholder that doesn't carry the
    /// `appintents-feature-view` identifier). Sabotage-verified: reverting
    /// `AppIntentsFeature.makeView(env:)` to `AnyView(NotYetPortedView(title: title))`
    /// and re-running this test produced a red failure on this exact
    /// assertion — see the PR description for the observed output.
    func test_sidebarAppIntentsRow_rendersRealFeatureView() throws {
        let app = launchApp()
        openAppIntentsFeature(in: app)
    }

    /// Drives the real registration button and asserts the screen read the
    /// new definition back from the `ToolRegistry` owned by `AppEnvironment`.
    /// A local Boolean flip cannot satisfy this assertion because the status
    /// label is populated from `toolRegistry.definitions` after registration.
    func test_registerSetReminder_executesThroughInferenceServiceRegistry() throws {
        let app = launchApp(additionalArguments: ["--appintent-tool-turn"])
        openAppIntentsFeature(in: app)

        let registerButton = app.buttons["appintent-tools-register-button"]
        XCTAssertTrue(
            waitForElement(registerButton, timeout: 5),
            "The live AppIntent tool screen should expose its registration button"
        )
        registerButton.tap()

        let status = app.staticTexts["appintent-tools-registration-status"]
        XCTAssertTrue(
            waitForElement(status, timeout: 5),
            "Registration should be confirmed by reading set_reminder_intent back from the live chat ToolRegistry"
        )
        XCTAssertEqual(status.label, "Registered in live chat registry: set_reminder_intent")
        XCTAssertFalse(registerButton.isEnabled, "A registered tool should not be registered twice")

        openChatFeature(in: app)
        guard let input = findMessageInput(app: app) else {
            XCTFail("Message input should exist for the AppIntent tool turn")
            return
        }
        input.tap()
        input.typeText("Use the reminder tool")
        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(waitForElement(sendButton, timeout: 3) && sendButton.isEnabled)
        sendButton.tap()

        let approveButton = app.buttons["approval-sheet-approve-button"]
        XCTAssertTrue(
            waitForElement(approveButton, timeout: 10),
            "InferenceService should route the registered AppIntent call through the shared production approval sheet"
        )
        approveButton.tap()

        let completedInvocation = app.descendants(matching: .any)[
            "tool-invocation-completed-set_reminder_intent"
        ].firstMatch
        XCTAssertTrue(
            waitForElement(completedInvocation, timeout: 15),
            "The live registry must complete SetReminderIntent; an unknown/UI-only registry produces a failed invocation"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["tool-invocation-failed-set_reminder_intent"].exists,
            "SetReminderIntent must not finish as a failed tool invocation"
        )

        let completed = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Reminder completed through the live registry'")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(completed, timeout: 15),
            "The turn should execute set_reminder_intent through InferenceService's registry, then continue to the scripted completion"
        )
    }

    func test_runtimeWiring_reportsSharedRegistryStartupHandlerAndAppGroup() throws {
        let app = launchApp()
        openAppIntentsFeature(in: app)

        XCTAssertEqual(
            app.staticTexts["appintent-chat-registry-status"].label,
            "Chat registry connected"
        )
        XCTAssertEqual(
            app.staticTexts["appintent-background-handler-status"].label,
            "Background intent handler configured during bootstrap"
        )
    }

    func test_coldLaunchEnvelope_isIngestedOnlyAfterModelReadiness() throws {
        let prompt = "Cold launch AppIntent prompt"
        let app = launchApp(additionalArguments: ["--appintent-prompt", prompt])
        openChatDetailIfNeeded(app: app)

        let ingestedPrompt = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", prompt)
        ).firstMatch
        XCTAssertTrue(
            waitForElement(ingestedPrompt, timeout: 15),
            "Startup should drain the real App Group envelope and ingest it once the scripted model publishes ready"
        )
    }

    /// Launches without a cold-start payload, then opens the app's registered
    /// route while it is already running. The prompt can appear only if
    /// RootView's real `.onOpenURL` closure takes the seeded App Group slot,
    /// stages it, reinstalls readiness delivery, and ingests it into Chat.
    func test_warmInboundURL_routesThroughRootViewIntoLiveChat() throws {
        let prompt = "Warm URL AppIntent prompt"
        let app = launchApp(additionalArguments: ["--warm-appintent-prompt", prompt])
        openAppIntentsFeature(in: app)

        let seedStatus = app.staticTexts["appintent-inbound-handoff-status"]
        XCTAssertTrue(waitForElement(seedStatus, timeout: 5))
        XCTAssertEqual(
            seedStatus.label,
            "Warm AppIntent UI-test envelope awaiting URL route.",
            "The test seed must remain outside startup staging until the running scene receives its URL event"
        )

        guard let route = InboundAppIntentRoute.url else {
            XCTFail("The registered warm AppIntent route must be constructible")
            return
        }
        app.open(route)

        openChatDetailIfNeeded(app: app)
        let ingestedPrompt = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", prompt)
        ).firstMatch
        XCTAssertTrue(
            waitForElement(ingestedPrompt, timeout: 15),
            "The running scene must route manifold://ingest through RootView into the live Chat detail"
        )
    }

    func test_malformedColdLaunchEnvelope_isDiscardedAndReported() throws {
        let app = launchApp(additionalArguments: ["--appintent-malformed-envelope"])
        openAppIntentsFeature(in: app)

        let status = app.staticTexts["appintent-inbound-handoff-status"]
        XCTAssertTrue(waitForElement(status, timeout: 5))
        XCTAssertEqual(status.label, "Malformed inbound AppIntent payload discarded.")
    }

    private func openAppIntentsFeature(in app: XCUIApplication) {
        tapFeatureSidebarButton("appintents", in: app)

        XCTAssertTrue(
            waitForElement(app.descendants(matching: .any)["appintents-feature-view"], timeout: 5),
            "AppIntents feature should render its live view"
        )
    }

    private func openChatFeature(in app: XCUIApplication) {
        tapFeatureSidebarButton("chat", in: app)
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "Selecting Chat should restore the live chat detail before driving the registered AppIntent tool"
        )
    }

    private func tapFeatureSidebarButton(_ featureID: String, in app: XCUIApplication) {
        XCTAssertTrue(
            tapFeatureSidebarRow(featureID, app: app),
            "Sidebar should expose a selectable \(featureID) feature row"
        )
    }

    private func makeIsolatedEnvelopeDefaults() -> UserDefaults? {
        UserDefaults(suiteName: "com.manifoldkit.AppIntentsUITests.\(UUID().uuidString)")
    }

    private func prompt(in result: InboundAppIntentEnvelopeStore.TakeResult) -> String? {
        guard case .payload(let payload) = result else { return nil }
        return payload.prompt
    }

    @MainActor
    private func waitForDeliveryState(
        _ expected: PendingPayloadBuffer.DeliveryState,
        in buffer: PendingPayloadBuffer
    ) async {
        for _ in 0..<100 {
            if await buffer.currentDeliveryState() == expected { return }
            await Task.yield()
        }
        XCTFail("Pending payload buffer did not reach expected state \(expected)")
    }
}

@MainActor
private final class PayloadRecorder {
    private(set) var payloads: [InboundPayload] = []

    func record(_ payload: InboundPayload) {
        payloads.append(payload)
    }
}

@MainActor
private final class HandoffStorageProbe {
    struct Entry: Equatable {
        let payload: Data
        let handoffID: UUID
    }

    private var payloads: [UUID: Data] = [:]
    private var currentHandoffID: UUID?

    var current: Entry? {
        guard let currentHandoffID,
              let payload = payloads[currentHandoffID] else {
            return nil
        }
        return Entry(payload: payload, handoffID: currentHandoffID)
    }

    @discardableResult
    func write(_ handoffID: UUID) -> UUID {
        payloads[handoffID] = Data()
        currentHandoffID = handoffID
        return handoffID
    }

    @discardableResult
    func write(payload: Data, handoffID: UUID) -> UUID {
        payloads[handoffID] = payload
        currentHandoffID = handoffID
        return handoffID
    }

    func discardWrittenPayload(_ handoffID: UUID) {
        payloads[handoffID] = nil
    }

    func contains(_ handoffID: UUID) -> Bool {
        payloads[handoffID] != nil
    }
}

private actor ReadinessGateProbe {
    private var isWaiting = false
    private var isReady = false
    private var didStartGeneration = false
    private var waitStartContinuation: CheckedContinuation<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?

    func waitForReady() async {
        isWaiting = true
        waitStartContinuation?.resume()
        waitStartContinuation = nil
        guard !isReady else { return }
        await withCheckedContinuation { readyContinuation = $0 }
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { waitStartContinuation = $0 }
    }

    func markReady() {
        isReady = true
        readyContinuation?.resume()
        readyContinuation = nil
    }

    func recordGeneration() {
        didStartGeneration = true
    }

    var didGenerate: Bool { didStartGeneration }
}

private actor DeliveryAcknowledgementProbe {
    private var isWaiting = false
    private var isReleased = false
    private var waitingContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        isWaiting = true
        waitingContinuation?.resume()
        waitingContinuation = nil
        guard !isReleased else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { waitingContinuation = $0 }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

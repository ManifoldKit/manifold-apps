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
    }

    func test_envelope_decodesLegacyShapeWithoutAttachmentsField() throws {
        // A payload written before `attachments` existed must still decode
        // rather than throwing on a missing key.
        let legacyJSON = #"{"prompt":"hello","source":"appIntent"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(InboundPayloadEnvelope.self, from: legacyJSON)

        XCTAssertEqual(decoded.prompt, "hello")
        XCTAssertEqual(decoded.source, "appIntent")
        XCTAssertTrue(decoded.attachments.isEmpty)
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
    }

    // MARK: - Readiness-aware delivery

    @MainActor
    func test_pendingPayload_waitsForReadyThenDrainsExactlyOnce() async {
        let buffer = PendingPayloadBuffer()
        let payload = InboundPayload(prompt: "deliver after load", source: .appIntent)
        await buffer.store(payload)

        let (updates, continuation) = AsyncStream<ModelLoadReadinessState>.makeStream()
        let recorder = PayloadRecorder()
        let delivery = Task {
            await buffer.deliverWhenModelReady(readinessUpdates: updates) { inbound in
                recorder.record(inbound)
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
        await buffer.store(InboundPayload(prompt: "keep me", source: .appIntent))
        let recorder = PayloadRecorder()
        let updates = AsyncStream<ModelLoadReadinessState> { continuation in
            continuation.yield(.idle)
            continuation.yield(.loading(progress: 0.25))
            continuation.finish()
        }

        await buffer.deliverWhenModelReady(readinessUpdates: updates) { inbound in
            recorder.record(inbound)
        }

        let retained = await buffer.peek()
        let finalState = await buffer.currentDeliveryState()
        XCTAssertEqual(retained?.prompt, "keep me")
        XCTAssertEqual(finalState, .readinessStreamEnded)
        XCTAssertTrue(recorder.payloads.isEmpty, "A readiness stream ending early must not silently consume the payload")
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
        showSidebarIfNeeded(app: app)

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'App Intents'"))
            .firstMatch
        XCTAssertTrue(waitForElement(row, timeout: 5), "Sidebar should show an 'App Intents' row")
        row.tap()

        let featureView = app.descendants(matching: .any)["appintents-feature-view"]
        XCTAssertTrue(
            waitForElement(featureView, timeout: 5),
            "AppIntentsFeature.makeView(env:) should render a view carrying the 'appintents-feature-view' accessibility identifier — NotYetPortedView (and any other placeholder) never sets this identifier"
        )
    }

    /// Drives the real registration button and asserts the screen read the
    /// new definition back from the `ToolRegistry` owned by `AppEnvironment`.
    /// A local Boolean flip cannot satisfy this assertion because the status
    /// label is populated from `toolRegistry.definitions` after registration.
    func test_registerSetReminder_executesThroughInferenceServiceRegistry() throws {
        let app = launchApp(additionalArguments: ["--appintent-tool-turn"])
        showSidebarIfNeeded(app: app)

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'App Intents'"))
            .firstMatch
        XCTAssertTrue(waitForElement(row, timeout: 5), "Sidebar should show an 'App Intents' row")
        row.tap()

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

        showSidebarIfNeeded(app: app)
        let chatRow = app.staticTexts["chat-sidebar-row"]
        XCTAssertTrue(waitForElement(chatRow, timeout: 5), "Sidebar should expose the Chat row")
        chatRow.tap()
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "The scripted chat backend should be ready before driving the registered AppIntent tool"
        )
        guard let input = findMessageInput(app: app) else {
            XCTFail("Message input should exist for the AppIntent tool turn")
            return
        }
        input.tap()
        input.typeText("Use the reminder tool")
        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(waitForElement(sendButton, timeout: 3) && sendButton.isEnabled)
        sendButton.tap()

        let toolResult = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Reminder noted: review the live registry'")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(toolResult, timeout: 15),
            "The live registry must execute SetReminderIntent; an unknown/UI-only registry cannot produce its reminder result"
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
            "Background intent handler configured"
        )
        #if os(iOS)
        XCTAssertEqual(
            app.staticTexts["appintent-app-group-status"].label,
            "App Group available"
        )
        #endif
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

    func test_malformedColdLaunchEnvelope_isDiscardedAndReported() throws {
        let app = launchApp(additionalArguments: ["--appintent-malformed-envelope"])
        openAppIntentsFeature(in: app)

        let status = app.staticTexts["appintent-inbound-handoff-status"]
        XCTAssertTrue(waitForElement(status, timeout: 5))
        XCTAssertEqual(status.label, "Malformed inbound AppIntent payload discarded.")
    }

    private func openAppIntentsFeature(in app: XCUIApplication) {
        showSidebarIfNeeded(app: app)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'App Intents'"))
            .firstMatch
        XCTAssertTrue(waitForElement(row, timeout: 5), "Sidebar should show an 'App Intents' row")
        row.tap()

        XCTAssertTrue(
            waitForElement(app.descendants(matching: .any)["appintents-feature-view"], timeout: 5),
            "AppIntents feature should render its live view"
        )
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

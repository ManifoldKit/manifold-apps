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
        // `AppIntentsFeature.readInboundEnvelope()` (and any future
        // out-of-process consumer) can find it.
        let envelope = InboundPayloadEnvelope(prompt: "p", attachments: [.text("a")], source: "appIntent")

        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(object?["attachments"])
        XCTAssertEqual((object?["attachments"] as? [Any])?.count, 1)
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
    func test_registerSetReminder_addsDefinitionToLiveChatRegistry() throws {
        let app = launchApp()
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
    }
}

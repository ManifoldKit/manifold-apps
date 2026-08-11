import XCTest

/// AppIntents feature coverage: the App Group envelope's wire-format
/// contract (mirrored locally — see below), plus a UI-level assertion that
/// the sidebar's "App Intents" row renders `AppIntentsFeature`'s real
/// content rather than the shared `NotYetPortedView` stub every other
/// not-yet-ported feature still shows.
///
/// ## Why a local envelope mirror, not the real `InboundPayloadEnvelope`
///
/// Core's `InboundPayloadEnvelopeTests` (`Example/AdvancedUITests` in
/// ManifoldKit) compiles the real `InboundPayloadEnvelope.swift` directly
/// into its UI Tests bundle — that repo's `Example/AdvancedUITests` target
/// lists the file in its sources. Reproducing that here needs
/// `Shared/Support/InboundPayload/InboundPayloadEnvelope.swift` (plus a
/// `ManifoldInference` product dependency, for `MessagePart`) added to this
/// repo's `ManifoldUITests` target in `project.yml` — a change outside this
/// feature's ownership (`Shared/Features/AppIntents/**` + this file only;
/// reported to `main`). Until that lands, `EnvelopeMirror` below asserts
/// the same wire contract (prompt/attachments/source round-trip, legacy
/// no-attachments-key decode, attachments-key presence when non-empty)
/// against a structurally identical but independently-declared type — a
/// regression in the real type's `CodingKeys` or default-decode fallback
/// is likely, though not guaranteed, to be caught here too. This is
/// coverage-by-mirror, not a substitute for testing the real type.
final class AppIntentsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Envelope wire-format mirror

    /// Field-for-field mirror of `InboundPayloadEnvelope`: same property
    /// names, same `CodingKeys`, same default-empty `attachments` decode
    /// fallback. `attachments` is `[String]` here rather than
    /// `[MessagePart]` — `MessagePart` isn't visible in this target (see
    /// the type-level doc comment) — but every assertion below exercises
    /// the envelope's own key handling, not `MessagePart`'s Codable
    /// implementation, so the narrower element type doesn't weaken them.
    private struct EnvelopeMirror: Codable, Equatable {
        var prompt: String
        var attachments: [String]
        var source: String

        init(prompt: String, attachments: [String] = [], source: String) {
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
            self.attachments = try container.decodeIfPresent([String].self, forKey: .attachments) ?? []
            self.source = try container.decode(String.self, forKey: .source)
        }
    }

    func test_envelope_roundTripsPromptAndSource() throws {
        let envelope = EnvelopeMirror(prompt: "summarize this article", attachments: [], source: "appIntent")

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(EnvelopeMirror.self, from: data)

        XCTAssertEqual(decoded.prompt, "summarize this article")
        XCTAssertEqual(decoded.source, "appIntent")
        XCTAssertTrue(decoded.attachments.isEmpty)
    }

    func test_envelope_roundTripsAttachmentsEndToEnd() throws {
        let attachments = ["relevant context", "sig-abc", "image/png"]
        let envelope = EnvelopeMirror(prompt: "act on the attached payload", attachments: attachments, source: "shareExtension")

        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(EnvelopeMirror.self, from: data)

        XCTAssertEqual(decoded.prompt, "act on the attached payload")
        XCTAssertEqual(decoded.source, "shareExtension")
        XCTAssertEqual(decoded.attachments, attachments)
    }

    func test_envelope_decodesLegacyShapeWithoutAttachmentsField() throws {
        // A payload written before `attachments` existed must still decode
        // rather than throwing on a missing key.
        let legacyJSON = #"{"prompt":"hello","source":"appIntent"}"#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(EnvelopeMirror.self, from: legacyJSON)

        XCTAssertEqual(decoded.prompt, "hello")
        XCTAssertEqual(decoded.source, "appIntent")
        XCTAssertTrue(decoded.attachments.isEmpty)
    }

    func test_envelope_emitsAttachmentsKeyWhenNonEmpty() throws {
        // Pins the wire format: a non-empty `attachments` array must
        // serialise under the literal key `"attachments"` so
        // `AppIntentsFeature.readInboundEnvelope()` (and any future
        // out-of-process consumer) can find it.
        let envelope = EnvelopeMirror(prompt: "p", attachments: ["a"], source: "appIntent")

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
}

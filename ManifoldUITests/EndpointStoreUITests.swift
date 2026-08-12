import XCTest

/// Pins the host-side `EndpointStore` wiring used by ChatView's injected
/// API-configuration surface.
final class EndpointStoreUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp(additionalArguments: ["--show-api-key-recovery"])
    }

    /// Drives ChatView's real API-key recovery presentation rather than
    /// mounting APIConfigurationView in a synthetic probe. Under
    /// `--uitesting`, persistence is in-memory. Leaving the API key empty
    /// also avoids a Keychain write, while Save still has to call
    /// `EndpointStore.insertEndpoint` before dismissing.
    func testAPIKeyRecoveryCanSaveEndpoint() throws {
        openChatDetailIfNeeded(app: app)

        let recoveryButton = app.buttons["Check API Key"]
        XCTAssertTrue(
            recoveryButton.waitForExistence(timeout: 5) && recoveryButton.isHittable,
            "The seeded configuration error should expose ChatView's Check API Key recovery action"
        )
        recoveryButton.tap()

        let cloudTitle = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Cloud APIs' OR value == 'Cloud APIs'")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(cloudTitle, timeout: 5),
            "Check API Key should present the injected APIConfigurationView"
        )

        let addEndpoint = app.buttons["Add Endpoint"].exists
            ? app.buttons["Add Endpoint"]
            : app.descendants(matching: .any).matching(
                NSPredicate(format: "label == 'Add Endpoint'")
            ).firstMatch
        XCTAssertTrue(
            waitForElement(addEndpoint, timeout: 3) && addEndpoint.isHittable,
            "APIConfigurationView should expose Add Endpoint"
        )
        addEndpoint.tap()

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 5),
            "The endpoint editor should present a Save button"
        )

        let readyDeadline = Date().addingTimeInterval(3)
        while !saveButton.isEnabled && Date() < readyDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            saveButton.isEnabled && saveButton.isHittable,
            "The default endpoint fields should populate and enable Save"
        )
        saveButton.tap()

        let missingStoreError = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Endpoint store is not configured'")
        ).firstMatch
        let editorDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: saveButton
        )
        let result = XCTWaiter.wait(for: [editorDismissed], timeout: 5)

        if result != .completed {
            captureScreenshot(name: "Endpoint-Store-Save-Failed")
        }
        XCTAssertFalse(
            missingStoreError.exists,
            "The injected API configuration content must provide EndpointStore to its nested editor"
        )
        XCTAssertEqual(
            result,
            .completed,
            "Saving through API-key recovery should persist to the in-memory store and dismiss the editor"
        )

        let savedEndpoint = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'OpenAI' OR value CONTAINS[c] 'OpenAI'")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(savedEndpoint, timeout: 3),
            "The saved default endpoint should appear in the Cloud APIs list"
        )
    }
}

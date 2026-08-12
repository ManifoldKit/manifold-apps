import XCTest

/// Coverage for ``CloudFeature`` — the sidebar-reachable cloud API endpoint
/// manager. Selectively ported from core's
/// `Example/AdvancedUITests/CloudAPIUITests.swift` (243 LOC): the endpoint
/// list / add-endpoint flow is kept, the live-cloud round-trip paths are
/// dropped, and navigation is rewritten for this app's sidebar-feature shape
/// instead of core's Settings → Advanced → "Manage Cloud APIs" disclosure
/// chain (`APIConfigurationView` itself, and its field labels, are
/// unchanged — see `CloudFeature.swift`'s doc comment for why the two
/// navigation paths differ).
///
/// SAFETY: no live network calls and no real Keychain writes. The save-flow
/// test leaves the API-key field empty, so `EndpointStore.insertEndpoint`
/// writes only to the in-memory SwiftData store installed under
/// `--uitesting`; `KeychainService.store` is skipped by the editor for an
/// empty key. The test selects the resulting endpoint but never sends a
/// message, so the configured backend makes no network request.
final class CloudUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp()
    }

    // MARK: - Navigation

    /// Sabotage-checked (see PR body): reverting `CloudFeature.makeView` to
    /// `NotYetPortedView` makes this fail, because the "Cloud APIs" title
    /// this test waits for is `APIConfigurationView`'s `.navigationTitle`,
    /// not anything `NotYetPortedView` renders.
    func testOpenCloudFeatureShowsAPIConfiguration() throws {
        navigateToCloudFeature()
        captureScreenshot(name: "Cloud-Feature-Opened")
    }

    // MARK: - CloudAPIUITests.testEmptyStateMessage

    func testEmptyStateMessage() throws {
        navigateToCloudFeature()

        // Every UI-test launch gets a fresh in-memory store, so accepting the
        // always-present section header here would make this assertion
        // tautological.
        let emptyText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'No cloud APIs configured'")).firstMatch

        captureScreenshot(name: "Cloud-Feature-Empty-State")
        XCTAssertTrue(
            waitForElement(emptyText, timeout: 3),
            "A fresh in-memory endpoint store should show the empty-state message"
        )
    }

    // MARK: - CloudAPIUITests.testAddEndpointFlow

    func testSavedEndpointAppearsInModelSwitcherAndCanBeSelected() throws {
        navigateToCloudFeature()

        let addButton: XCUIElement
        if app.buttons["Add Endpoint"].waitForExistence(timeout: 3) {
            addButton = app.buttons["Add Endpoint"]
        } else {
            addButton = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Add Endpoint'")).firstMatch
        }
        guard waitForElement(addButton, timeout: 3) else {
            captureScreenshot(name: "Cloud-Add-No-Button")
            XCTFail("Add Endpoint button not found")
            return
        }

        addButton.tap()

        let editorTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Add Endpoint' OR value == 'Add Endpoint'"))
            .firstMatch
        XCTAssertTrue(
            waitForElement(editorTitle, timeout: 5),
            "Endpoint editor should appear with an 'Add Endpoint' title"
        )

        // `populateFields()` immediately replaces the three TextField
        // prompts with the default provider's values. On current iOS the
        // resulting accessibility elements expose those values but not the
        // original prompt labels, so assert the published OpenAI defaults
        // the editor actually rendered instead of searching for prompts
        // that are no longer in the accessibility tree.
        XCTAssertGreaterThanOrEqual(
            app.textFields.count, 3,
            "Editor should contain at least 3 text fields (Display Name, Server URL, Model Name)"
        )
        for expectedValue in ["OpenAI", "https://api.openai.com", "gpt-4o-mini"] {
            let populatedField = app.textFields.matching(
                NSPredicate(format: "value == %@", expectedValue)
            ).firstMatch
            XCTAssertTrue(
                populatedField.waitForExistence(timeout: 3),
                "Endpoint editor should populate a field with the default value \(expectedValue)"
            )
        }

        captureScreenshot(name: "Cloud-Add-Editor-Fields")

        // Leave API Key empty: the editor persists the record but skips its
        // Keychain write (see SAFETY above).
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 3),
            "Endpoint editor should expose its Save action"
        )
        XCTAssertTrue(saveButton.isEnabled && saveButton.isHittable, "Populated defaults should enable Save")
        saveButton.tap()

        let editorGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: saveButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [editorGone], timeout: 3),
            .completed,
            "A successful EndpointStore insert should dismiss the editor"
        )

        let missingStoreError = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Endpoint store is not configured'")
        ).firstMatch
        XCTAssertFalse(missingStoreError.exists, "CloudFeature must inject its EndpointStore into the editor")

        let savedEndpoint = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'OpenAI' OR value CONTAINS[c] 'OpenAI'")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(savedEndpoint, timeout: 3),
            "The saved default endpoint should appear in the Cloud APIs list"
        )

        // Leaving Cloud causes RootView to refresh ChatViewModel's public
        // endpoint list from the store. The resulting row is the proof that
        // persistence is connected to the chat surface, not only to this form.
        showSidebarIfNeeded(app: app)
        let chatRow = app.staticTexts["chat-sidebar-row"]
        XCTAssertTrue(
            chatRow.waitForExistence(timeout: 5),
            "Sidebar should expose an explicit route back to ChatView"
        )
        if chatRow.isHittable {
            chatRow.tap()
        } else {
            chatRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        let chip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        XCTAssertTrue(chip.waitForExistence(timeout: 5) && chip.isHittable, "Chat should expose its model switcher")
        chip.tap()

        let switcher = app.descendants(matching: .any)["model-switcher-list"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "Model switcher should open")
        let endpointRow = switcher.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'OpenAI'")
        ).firstMatch
        XCTAssertTrue(
            endpointRow.waitForExistence(timeout: 5) && endpointRow.isHittable,
            "The saved endpoint must be published into ChatViewModel.availableEndpoints"
        )
        endpointRow.tap()

        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS[c] 'In use'"),
            object: endpointRow
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selected], timeout: 5),
            .completed,
            "Selecting a saved endpoint should make it the active chat choice"
        )

        captureScreenshot(name: "Cloud-Endpoint-In-Model-Switcher")

        // The UI-test bootstrap deliberately does not register live cloud
        // factories. A dispatched load therefore fails locally before any
        // network request; requiring that deterministic failure proves
        // RootView did more than assign `selectedEndpoint`.
        dismissSheet(app: app)
        let dispatchedLoadFailure = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Failed to connect'")
        ).firstMatch
        XCTAssertTrue(
            dispatchedLoadFailure.waitForExistence(timeout: 5),
            "Selecting an endpoint must dispatch its load; the UI-test backend should fail locally with 'Failed to connect'"
        )
    }

    // MARK: - Helpers

    /// Navigates from the sidebar to the Cloud feature's `APIConfigurationView`.
    private func navigateToCloudFeature() {
        showSidebarIfNeeded(app: app)

        let cloudRow: XCUIElement = {
            if app.buttons["Cloud"].waitForExistence(timeout: 2) {
                return app.buttons["Cloud"]
            }
            if app.cells["Cloud"].waitForExistence(timeout: 1) {
                return app.cells["Cloud"]
            }
            return app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Cloud'"))
                .firstMatch
        }()

        guard waitForElement(cloudRow, timeout: 5) else {
            captureScreenshot(name: "Cloud-Nav-Row-Not-Found")
            XCTFail("Cloud sidebar row not found")
            return
        }
        cloudRow.tap()

        let apiTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Cloud APIs' OR value == 'Cloud APIs'"))
            .firstMatch
        guard waitForElement(apiTitle, timeout: 5) else {
            captureScreenshot(name: "Cloud-Nav-Feature-Not-Opened")
            XCTFail("Cloud feature did not present the API Configuration view (title 'Cloud APIs' not found)")
            return
        }
    }
}

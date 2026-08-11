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
/// SAFETY: no live network calls and no real Keychain writes. Every test
/// here stops at "Add Endpoint" → assert the editor rendered → Cancel; none
/// taps "Save", so `EndpointStore.insertEndpoint` and
/// `KeychainService.store` are never invoked. The in-memory SwiftData store
/// used under `--uitesting` (`AppEnvironment.bootstrap`) means even a
/// hypothetical save would not touch a real on-disk store, but avoiding the
/// tap entirely also means avoiding a real Keychain write, which the
/// in-memory store swap does NOT protect against.
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

    func testEmptyStateOrEndpointsList() throws {
        navigateToCloudFeature()

        // Under `--uitesting` no endpoints are seeded, so the empty-state
        // Text should render; if that ever changes, the "Endpoints" section
        // header is the other valid state (mirrors core's same fallback).
        let emptyText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'No cloud APIs configured'")).firstMatch
        let hasEmptyState = waitForElement(emptyText, timeout: 3)

        captureScreenshot(name: "Cloud-Feature-Empty-State")

        if !hasEmptyState {
            let endpointsSection = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Endpoints'")).firstMatch
            XCTAssertTrue(
                waitForElement(endpointsSection, timeout: 3),
                "Should show either the empty-state message or the Endpoints section"
            )
        }
    }

    // MARK: - CloudAPIUITests.testAddEndpointFlow

    func testAddEndpointFlowRendersEditorThenCancels() throws {
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

        for fieldLabel in ["Display Name", "Server URL", "Model Name"] {
            let label = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ OR value == %@", fieldLabel, fieldLabel))
                .firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 3), "\(fieldLabel) label should exist in editor")
        }
        XCTAssertGreaterThanOrEqual(
            app.textFields.count, 3,
            "Editor should contain at least 3 text fields (Display Name, Server URL, Model Name)"
        )

        captureScreenshot(name: "Cloud-Add-Editor-Fields")

        // Cancel — never tap Save (see SAFETY note above).
        let cancelButton = app.buttons["Cancel"]
        if waitForElement(cancelButton, timeout: 2) {
            cancelButton.tap()
        } else {
            dismissSheet(app: app)
        }

        let editorGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: editorTitle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [editorGone], timeout: 3),
            .completed,
            "Endpoint editor should dismiss after Cancel"
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

import XCTest

/// Acceptance coverage for the always-available Explore documentation surface.
/// The setup actions must enter the host's existing screens rather than a
/// feature-owned registry or placeholder view.
final class ExploreUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp()
    }

    func testExploreRendersRealExamplesChangesThemeAndUsesExistingSetupRoutes() throws {
        navigateToExplore()

        XCTAssertTrue(app.descendants(matching: .any)["explore-component-reference"].waitForExistence(timeout: 5))
        let userExample = app.descendants(matching: .any)["explore-user-message"]
        let assistantExample = app.descendants(matching: .any)["explore-assistant-message"]
        XCTAssertTrue(userExample.waitForExistence(timeout: 5))
        XCTAssertTrue(userExample.label.contains("Can a conversation include Markdown?"))
        XCTAssertTrue(assistantExample.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantExample.label.contains("Markdown and code"))
        XCTAssertTrue(app.descendants(matching: .any)["explore-message-bubble-source"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["explore-theming-showcase"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Guided"].exists)
        XCTAssertFalse(app.staticTexts["Live"].exists)

        let readout = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        let standard = readout.label

        let brand = app.buttons["Brand"]
        XCTAssertTrue(tapExploreElement(brand), "Brand must be reachable through the bounded Explore scroll path")
        XCTAssertNotEqual(readout.label, standard, "Brand must change the actual root-installed theme readout")

        let reset = app.descendants(matching: .any)["theming-reset-button"]
        XCTAssertTrue(tapExploreElement(reset), "Reset must be reachable through the bounded Explore scroll path")
        XCTAssertEqual(readout.label, standard, "Reset must restore the Standard theme in the live cascade")

        let models = app.descendants(matching: .any)["explore-show-models"]
        XCTAssertTrue(tapExploreElement(models), "Models must be reachable through the bounded Explore scroll path")
        XCTAssertTrue(
            app.descendants(matching: .any)["model-management-tab-picker"].waitForExistence(timeout: 5),
            "Models must open RootView's existing ModelManagementSheet"
        )
        dismissSheet(app: app)

        navigateToExplore()
        let cloud = app.descendants(matching: .any)["explore-show-cloud"]
        XCTAssertTrue(tapExploreElement(cloud), "Cloud providers must be reachable through the bounded Explore scroll path")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == 'Cloud APIs' OR value == 'Cloud APIs'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Cloud providers must route to the existing API configuration surface"
        )
    }

    func testExploreNavigationPreservesRestoredActiveSessionAcrossIsolatedRelaunch() throws {
        let storeID = UUID().uuidString
        let freshStoreID = UUID().uuidString
        let marker = "Explore relaunch \(storeID)"
        app.terminate()
        app = launchRelaunchStore(storeID: storeID)
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 15))

        // Make a second real session active. Restoring the only session would
        // not prove that the persisted active-session identity was honoured.
        showSidebarIfNeeded(app: app)
        guard let newChat = findNewChatButton(app: app) else {
            XCTFail("The persisted-store launch must expose New Chat")
            return
        }
        newChat.tap()
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 10))

        guard let input = findMessageInput(app: app) else {
            XCTFail("A persisted-store launch should still expose the scripted chat composer")
            return
        }
        input.tap()
        input.typeText(marker)
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled)
        send.tap()
        XCTAssertEqual(
            waitForCompletedChatTurn(app: app, timeout: 15),
            "Response complete: Hello from the scripted UI-test backend."
        )

        app.terminate()
        app = launchRelaunchStore(storeID: storeID)
        openChatDetailIfNeeded(app: app)

        let restoredResponse = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", marker)
        ).firstMatch
        XCTAssertTrue(
            restoredResponse.waitForExistence(timeout: 10),
            "The active session selected before relaunch must restore with its persisted conversation"
        )

        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        XCTAssertTrue(app.descendants(matching: .any)["explore-root"].waitForExistence(timeout: 5))

        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(
            restoredResponse.exists,
            "Leaving Explore must retain the restored active conversation"
        )

        app.terminate()
        app = launchRelaunchStore(storeID: freshStoreID)
        openChatDetailIfNeeded(app: app)
        let leakedMessage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", marker)
        ).firstMatch
        XCTAssertFalse(
            leakedMessage.exists,
            "A different run-owned store UUID must not inherit a prior session or message"
        )
    }

    private func navigateToExplore() {
        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        XCTAssertTrue(
            app.descendants(matching: .any)["explore-root"].waitForExistence(timeout: 5),
            "Explore sidebar selection should present its app-owned detail"
        )
    }

    private func launchRelaunchStore(storeID: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["MANIFOLD_UI_TEST_STORE_ID"] = storeID
        app.launch()
        return app
    }

    /// Explore is intentionally a long, readable document. Compact iPhone
    /// tests must follow its actual scroll path before tapping lower controls.
    private func tapExploreElement(_ element: XCUIElement, maximumScrolls: Int = 4) -> Bool {
        let explore = app.descendants(matching: .any)["explore-root"]
        guard explore.waitForExistence(timeout: 5) else { return false }

        for _ in 0..<maximumScrolls {
            if element.exists && element.isHittable {
                element.tap()
                return true
            }
            explore.swipeUp()
        }

        if element.exists && element.isHittable {
            element.tap()
            return true
        }
        return false
    }
}

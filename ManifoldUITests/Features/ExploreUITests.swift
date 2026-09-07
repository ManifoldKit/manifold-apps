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
        let userLabel = "User said: Can a conversation include Markdown?"
        let assistantLabel = "Assistant said: Yes. **Markdown** and code render as regular message content.\n\n```swift\nlet theme = ManifoldTheme.standard\n```"
        let userExample = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", userLabel)
        ).firstMatch
        let assistantExample = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", assistantLabel)
        ).firstMatch
        XCTAssertTrue(userExample.waitForExistence(timeout: 5))
        XCTAssertTrue(assistantExample.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["explore-message-bubble-source"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["theming-preset-picker"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Guided"].exists)
        XCTAssertFalse(app.staticTexts["Live"].exists)
        captureScreenshot(name: "Explore-Component-Examples")

        let readout = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        let standard = readout.label

        let brand = app.buttons["Brand"]
        XCTAssertTrue(tapExploreElement(brand), "Brand must be reachable through the bounded Explore scroll path")
        XCTAssertNotEqual(readout.label, standard, "Brand must change the actual root-installed theme readout")
        captureScreenshot(name: "Explore-Brand-Theme")

        let reset = app.descendants(matching: .any)["theming-reset-button"]
        XCTAssertTrue(tapExploreElement(reset), "Reset must be reachable through the bounded Explore scroll path")
        XCTAssertEqual(readout.label, standard, "Reset must restore the Standard theme in the live cascade")

        let models = app.descendants(matching: .any)["explore-show-models"]
        XCTAssertTrue(tapExploreElement(models), "Models must be reachable through the bounded Explore scroll path")
        XCTAssertTrue(
            app.descendants(matching: .any)["model-management-tab-picker"].waitForExistence(timeout: 5),
            "Models must open RootView's existing ModelManagementSheet"
        )
        captureScreenshot(name: "Explore-Model-Management")
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
        captureScreenshot(name: "Explore-Cloud-Providers")
    }

    func testExploreNavigationPreservesRestoredActiveSessionAcrossIsolatedRelaunch() throws {
        let storeID = UUID().uuidString
        let freshStoreID = UUID().uuidString
        let olderMarker = "Explore older session \(storeID)"
        let newerMarker = "Explore newer session \(storeID)"
        app.terminate()
        app = launchRelaunchStore(storeID: storeID)
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 15))
        sendMessage(olderMarker)

        // Make two non-empty sessions, then select the older one. This proves
        // the persisted active-session identity wins over any latest-nonempty
        // fallback when the same isolated store is relaunched.
        showSidebarIfNeeded(app: app)
        guard let newChat = findNewChatButton(app: app) else {
            XCTFail("The persisted-store launch must expose New Chat")
            return
        }
        newChat.tap()
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 10))
        sendMessage(newerMarker)

        showSidebarIfNeeded(app: app)
        XCTAssertTrue(waitForSessionRows(count: 2), "The isolated store should retain two real session rows")
        let rows = sessionRows()
        guard rows.count == 2 else {
            XCTFail("The isolated store should expose exactly its two created session rows")
            return
        }
        // SessionStore's public contract orders rows by updatedAt descending.
        // The second turn is newer, so index 1 is the older conversation. Do
        // not use XCUIElement.isSelected: SessionRowView leaves that trait to
        // List(selection:) and its public row content defaults it to false.
        let olderSession = rows[1]
        olderSession.tap()
        XCTAssertTrue(messageElement(olderMarker).waitForExistence(timeout: 10))

        app.terminate()
        app = launchRelaunchStore(storeID: storeID)
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(
            messageElement(olderMarker).waitForExistence(timeout: 10),
            "The explicitly selected older session must restore instead of falling back to the newest non-empty session"
        )
        XCTAssertFalse(messageElement(newerMarker).exists, "The newer session must not become active after same-store relaunch")

        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        XCTAssertTrue(app.descendants(matching: .any)["explore-root"].waitForExistence(timeout: 5))

        XCTAssertTrue(
            tapFeatureSidebarRow("chat", app: app),
            "The existing Chat sidebar route must restore the active conversation without selecting another session"
        )
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 10))
        XCTAssertTrue(
            messageElement(olderMarker).exists,
            "Leaving Explore must retain the restored active conversation"
        )
        XCTAssertFalse(messageElement(newerMarker).exists)

        app.terminate()
        app = launchRelaunchStore(storeID: freshStoreID)
        openChatDetailIfNeeded(app: app)
        XCTAssertFalse(messageElement(olderMarker).exists, "A different store UUID must not inherit the older session")
        XCTAssertFalse(messageElement(newerMarker).exists, "A different store UUID must not inherit the newer session")
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

    private func sendMessage(_ message: String) {
        guard let input = findMessageInput(app: app) else {
            XCTFail("A persisted-store launch should expose the scripted chat composer")
            return
        }
        tapMessageEditingArea(input)
        input.typeText(message)
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled)
        send.tap()
        XCTAssertTrue(
            waitForCompletedChatTurn(app: app, timeout: 15)?.hasPrefix("Response complete:") == true,
            "Each persisted session must finish a real scripted turn before selection is tested"
        )
        XCTAssertTrue(
            messageElement(message).waitForExistence(timeout: 5),
            "The completed real turn must leave its component-derived user bubble visible before switching sessions"
        )
    }

    private func messageElement(_ marker: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "User said: \(marker)")
        ).firstMatch
    }

    private func sessionRows() -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'session-row'"))
            .allElementsBoundByIndex
    }

    private func waitForSessionRows(count: Int, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.sessionRows().count ?? 0) >= count
            },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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

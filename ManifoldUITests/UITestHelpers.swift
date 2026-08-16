import XCTest

/// Shared helpers for `SmokeUITests` — trimmed from ManifoldKit's own
/// `Example/AdvancedUITests/UITestHelpers.swift` (499 lines) down to just
/// what the 4 ported smoke tests need. Add helpers here only when a new
/// smoke test actually needs them — this file is not meant to grow into
/// core's full helper library.
extension XCTestCase {

    // MARK: - App Launch

    /// Launches the app in deterministic UI-testing mode.
    @discardableResult
    func launchApp(
        additionalArguments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        app.launchArguments += additionalArguments
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        #if os(macOS)
        // XCUIApplication termination can persist an intentional "all windows
        // closed" state even when ApplePersistenceIgnoreState is set. A later
        // test launch then owns the menu bar but has no window or app content.
        // Reopen the WindowGroup explicitly so each test starts from a visible,
        // independently reachable production surface.
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(
            app.windows.firstMatch.waitForExistence(timeout: 5),
            "App should present a window under macOS UI tests",
            file: file,
            line: line
        )
        // A GUI host that launched xcodebuild can remain frontmost even after
        // `activate()`. Click the tested window's title region directly: the
        // coordinate event is valid while its descendants are non-hittable,
        // and makes subsequent control interactions deterministic.
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.05))
            .tap()
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 5),
            "App should reach the foreground after focusing its window",
            file: file,
            line: line
        )
        #endif
        return app
    }

    // MARK: - Sidebar

    /// Shows the sidebar if the "Show Sidebar" button is visible (e.g. on compact layout).
    func showSidebarIfNeeded(app: XCUIApplication) {
        if isSidebarVisible(app: app) {
            return
        }

        let sidebarButtons = [
            app.buttons["show-sidebar-button"],
            app.buttons["Show Sidebar"]
        ]
        for sidebarButton in sidebarButtons where sidebarButton.waitForExistence(timeout: 2) {
            if sidebarButton.isHittable {
                sidebarButton.tap()
                if waitForSidebar(app: app) { return }
            }
            sidebarButton.coordinate(withNormalizedOffset: CGVector(dx: 1.0, dy: 0.5)).tap()
            if waitForSidebar(app: app) { return }
        }

        app.swipeRight()
        if waitForSidebar(app: app) { return }

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        _ = waitForSidebar(app: app)
    }

    private func isSidebarVisible(app: XCUIApplication) -> Bool {
        app.staticTexts["Chats"].exists
            || app.buttons["new-chat-button"].exists
            || identifiedSessionRow(app: app).exists
    }

    private func waitForSidebar(app: XCUIApplication, timeout: TimeInterval = 2) -> Bool {
        app.staticTexts["Chats"].waitForExistence(timeout: timeout)
            || app.buttons["new-chat-button"].waitForExistence(timeout: timeout)
            || identifiedSessionRow(app: app).waitForExistence(timeout: timeout)
    }

    /// Returns the feature row across both iPhone's explicit Button list and
    /// iPad's native selection List. SwiftUI exposes the latter as a cell or
    /// combined label rather than a Button, so callers must not constrain the
    /// XCUI element type.
    func featureSidebarRow(_ featureID: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "feature-sidebar-row-\(featureID)")
        ).firstMatch
    }

    /// Reveals and selects a feature row. Coordinate tapping is an intentional
    /// fallback for iPadOS NavigationSplitView: a native List row can report
    /// `isHittable == false` even though its selection hit region is live.
    @discardableResult
    func tapFeatureSidebarRow(
        _ featureID: String,
        app: XCUIApplication,
        maximumScrolls: Int = 4
    ) -> Bool {
        showSidebarIfNeeded(app: app)

        let featureList = app.descendants(matching: .any)["feature-sidebar-list"]
        guard featureList.waitForExistence(timeout: 2) else { return false }

        let row = featureSidebarRow(featureID, app: app)
        for _ in 0..<maximumScrolls where !row.exists || row.frame.isEmpty {
            featureList.swipeUp()
        }
        guard row.waitForExistence(timeout: 5), !row.frame.isEmpty else { return false }

        if row.isHittable {
            row.tap()
        } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    // MARK: - Chat Detail

    /// On compact layouts, the app may launch with the session list visible first.
    /// Tap the current session so the chat detail toolbar and input become accessible.
    func openChatDetailIfNeeded(app: XCUIApplication) {
        if isChatDetailVisible(app: app) {
            return
        }

        if app.staticTexts["Chats"].exists || app.buttons["new-chat-button"].exists {
            let outsideSidebar = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.2))
            outsideSidebar.tap()
            if isChatDetailVisible(app: app) { return }
            app.swipeLeft()
            if isChatDetailVisible(app: app) { return }
        }

        let firstSessionCell = firstSessionRow(app: app)
        if firstSessionCell.waitForExistence(timeout: 3), firstSessionCell.isHittable {
            firstSessionCell.tap()
        } else {
            let sessionText = app.staticTexts.matching(NSPredicate(
                format: "label == 'New Chat' OR label CONTAINS[c] 'updated'"
            )).firstMatch
            if sessionText.waitForExistence(timeout: 2), sessionText.isHittable {
                sessionText.tap()
            }
        }

        _ = waitForElement(app.buttons["chat-settings-button"], timeout: 3)
            || waitForElement(app.textFields["Message input"], timeout: 2)
            || waitForElement(app.staticTexts["No Model Selected"], timeout: 1)
            || waitForElement(app.staticTexts.matching(NSPredicate(
                format: "label CONTAINS[c] 'Welcome'"
            )).firstMatch, timeout: 1)
    }

    func isChatDetailVisible(app: XCUIApplication) -> Bool {
        app.buttons["chat-settings-button"].exists
            || app.textFields["Message input"].exists
            || app.staticTexts["No Model Selected"].exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Welcome'")).firstMatch.exists
    }

    // MARK: - Common Element Lookup

    func findNewChatButton(app: XCUIApplication) -> XCUIElement? {
        let candidates = [
            app.buttons["New Chat"],
            app.buttons["new-chat-button"],
            app.navigationBars.buttons["New Chat"],
            app.navigationBars.buttons["new-chat-button"],
            app.buttons.matching(NSPredicate(
                format: "label == 'Add' OR identifier == 'new-chat-button'"
            )).firstMatch
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: 2) {
            return candidate
        }

        return nil
    }

    func findMessageInput(app: XCUIApplication) -> XCUIElement? {
        let byLabel = app.textFields["Message input"]
        if waitForElement(byLabel, timeout: 3) { return byLabel }

        let first = app.textFields.firstMatch
        if waitForElement(first, timeout: 2) { return first }

        return nil
    }

    func firstSessionRow(app: XCUIApplication) -> XCUIElement {
        let identified = identifiedSessionRow(app: app)
        if identified.exists { return identified }

        let titledSession = app.staticTexts.matching(NSPredicate(
            format: "label == 'New Chat' OR label CONTAINS[c] 'updated'"
        )).firstMatch
        if titledSession.exists { return titledSession }

        return app.cells.firstMatch
    }

    private func identifiedSessionRow(app: XCUIApplication) -> XCUIElement {
        let identifiedCell = app.cells.matching(
            NSPredicate(format: "identifier == 'session-row'")
        ).firstMatch
        if identifiedCell.exists { return identifiedCell }

        return app.otherElements.matching(
            NSPredicate(format: "identifier == 'session-row'")
        ).firstMatch
    }

    // MARK: - Screenshots

    /// Takes a screenshot and attaches it to the current test for debugging.
    func captureScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Element Waiting

    /// Waits for an element to exist within the given timeout. Returns `true` if found.
    @discardableResult
    func waitForElement(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.waitForExistence(timeout: timeout)
    }

    /// Waits for the app-owned chat container to report a completed turn and
    /// returns its accessibility value. This avoids relying on lazy message
    /// bubble descendants, which iOS 27 can omit from XCUI's remote snapshot
    /// even while those bubbles are visibly rendered.
    func waitForCompletedChatTurn(
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> String? {
        let conversation = app.otherElements["chat-conversation"]
        guard conversation.waitForExistence(timeout: 5) else { return nil }

        let completed = NSPredicate(format: "value BEGINSWITH 'Response complete:'")
        let expectation = XCTNSPredicateExpectation(predicate: completed, object: conversation)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            return nil
        }
        return conversation.value as? String
    }

    func waitForChatTurnValue(
        _ expectedValue: String,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let conversation = app.otherElements["chat-conversation"]
        guard conversation.waitForExistence(timeout: 5) else { return false }

        let predicate = NSPredicate(format: "value == %@", expectedValue)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: conversation)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - Sheet Dismissal

    /// Dismisses a presented sheet by tapping the "Done" button if it exists,
    /// otherwise swipes down on the sheet.
    func dismissSheet(app: XCUIApplication) {
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 2), doneButton.isHittable {
            doneButton.tap()
        } else {
            let topCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            let bottomCoordinate = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            topCoordinate.press(forDuration: 0.05, thenDragTo: bottomCoordinate)
        }
    }

    // MARK: - Model readiness

    /// Default timeout is 60s — enough for a cold model "load" (the
    /// scripted backend is instant, but a real backend under `--uitesting`
    /// wiring elsewhere may not be).
    func waitForChatInputReady(app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        let messageInput = app.textFields["Message input"]
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if messageInput.waitForExistence(timeout: 1),
               messageInput.isEnabled,
               messageInput.isHittable {
                return true
            }
        }

        return false
    }
}

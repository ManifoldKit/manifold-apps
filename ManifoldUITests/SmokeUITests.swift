import XCTest

/// Cross-cutting smoke coverage — one method ported from each of three of
/// core's UI test suites (`ChatFlowUITests`, `ModelSwitcherChipUITests`,
/// `SessionManagementUITests`) so a single, deliberately small target
/// proves the app boots, shows its welcome state, sends a message, opens
/// the model switcher, and switches sessions. See
/// `Example/AdvancedUITests/` in ManifoldKit for the full suites these were
/// trimmed from — `testCreateNewSession` was deliberately NOT ported (core
/// dropped it on a real, verified failure: ambiguous "New Chat" match).
final class SmokeUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp()
    }

    // MARK: - ChatFlowUITests.testEmptyStateShowsWelcome

    func testEmptyStateShowsWelcome() throws {
        openChatDetailIfNeeded(app: app)

        // On macOS, list/form rows often combine into a single accessibility
        // element so the literal text isn't always exposed as a separate
        // `staticText`. Search across `descendants(matching: .any)` rather
        // than just `staticTexts`.
        let predicate = NSPredicate(
            format: """
            label CONTAINS[c] 'Welcome' \
            OR label CONTAINS[c] 'Send a message to start chatting' \
            OR label CONTAINS[c] 'No Model Selected'
            """
        )
        let anyEmptyText = app.descendants(matching: .any).matching(predicate).firstMatch

        let hasEmptyState = waitForElement(anyEmptyText, timeout: 5)

        captureScreenshot(name: "Empty-State")
        XCTAssertTrue(hasEmptyState, "Should show a welcome message, empty placeholder, or no-model state on launch")
    }

    // MARK: - ChatFlowUITests.testSendMessageFlow

    func testSendMessageFlow() throws {
        openChatDetailIfNeeded(app: app)

        // Unlike core's original (a live demo that can genuinely have no
        // model loaded), this app's contract is that AppEnvironment's
        // --uitesting path always has the composer enabled by the time
        // bootstrap finishes (ScriptedBackend's fixed-backend
        // InferenceService marks the model loaded immediately — see
        // AppEnvironment.swift). So an unavailable input here is a real
        // regression in that wiring, not an expected "no model" state —
        // fail hard instead of skipping gracefully.
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "Chat input should be enabled under --uitesting — ScriptedBackend's fixed-backend InferenceService marks the model loaded immediately, so a disabled input here means that wiring is broken, not that no model is loaded"
        )

        let input = findMessageInput(app: app)
        guard let input else {
            captureScreenshot(name: "Send-Flow-No-Input")
            XCTFail("Message input not found even though waitForChatInputReady succeeded")
            return
        }

        input.tap()
        input.typeText("Hello from UI test")

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(waitForElement(sendButton, timeout: 3) && sendButton.isEnabled, "Send button should be enabled once the input has text")

        sendButton.tap()

        let completion = waitForCompletedChatTurn(app: app, timeout: 10)
        captureScreenshot(name: "Send-Flow-After-Send")
        XCTAssertEqual(
            completion,
            "Response complete: Hello from the scripted UI-test backend.",
            "Sending must complete a real scripted turn and surface the assistant response"
        )
    }

    // MARK: - ModelSwitcherChipUITests.testSwitcherChipReachableAndOpensSwitcherOnCompactWidth

    func testSwitcherChipReachableAndOpensSwitcherOnCompactWidth() throws {
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "Chat input should become ready before exercising the toolbar"
        )

        let chip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        XCTAssertTrue(
            chip.waitForExistence(timeout: 5) && chip.isHittable,
            "chat-model-switcher-chip must be directly visible and tappable (#2307 parity)"
        )

        captureScreenshot(name: "switcher-chip")
        chip.tap()

        // `app.sheets` never matches SwiftUI sheet presentations on iOS —
        // wait for the switcher content itself (rows actually rendered).
        let sheetAppeared = app.descendants(matching: .any)["model-switcher-list"]
            .waitForExistence(timeout: 10)
        captureScreenshot(name: "switcher-sheet-open")
        XCTAssertTrue(sheetAppeared, "Tapping the model-switcher chip should present the switcher sheet")

        dismissSheet(app: app)
    }

    // MARK: - SessionManagementUITests.testSwitchBetweenSessions

    func testSwitchBetweenSessions() throws {
        showSidebarIfNeeded(app: app)

        guard let newChatButton = findNewChatButton(app: app) else {
            captureScreenshot(name: "No-New-Chat-Button-Switch")
            XCTFail("New Chat button not found")
            return
        }

        // Create a second real session when needed. Its activation may
        // collapse compact navigation to the chat detail, so reveal the
        // sidebar again before querying the session rows.
        if sessionRows().count < 2 {
            newChatButton.tap()
            showSidebarIfNeeded(app: app)
            XCTAssertTrue(
                waitForSessionRows(count: 2),
                "Creating a session should leave two selectable session rows"
            )
        }

        guard sessionRows().count >= 2 else {
            captureScreenshot(name: "Not-Enough-Sessions")
            XCTFail("Need at least 2 sessions for switching test")
            return
        }

        XCTAssertTrue(
            tapFeatureSidebarRow("tools", app: app),
            "Sidebar should expose a selectable Tools row"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["tools-browser"].waitForExistence(timeout: 5),
            "Selecting Tools should replace the chat detail before the session switch"
        )

        showSidebarIfNeeded(app: app)

        guard let inactiveSession = sessionRows().first(where: { !$0.isSelected }) else {
            captureScreenshot(name: "No-Inactive-Session")
            XCTFail("Need a non-active session row; tapping the active session would not exercise the switch")
            return
        }

        inactiveSession.tap()
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 10),
            "Selecting a different session while Tools is displayed should restore the live chat detail"
        )
        captureScreenshot(name: "Switch-Session-From-Tools")
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
}

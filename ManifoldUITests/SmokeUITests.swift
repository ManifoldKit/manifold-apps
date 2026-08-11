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

        // MessageBubbleView combines its content with
        // `accessibilityElement(.combine)` and exposes a "User said: <content>"
        // label on the wrapping element, which macOS exposes as an
        // `otherElement` rather than a `staticText`.
        let predicate = NSPredicate(format: "label CONTAINS[c] 'Hello from UI test'")
        let userMessage = app.descendants(matching: .any).matching(predicate).firstMatch

        let messageAppeared = waitForElement(userMessage, timeout: 5)
        captureScreenshot(name: "Send-Flow-After-Send")
        XCTAssertTrue(messageAppeared, "User message should appear in the chat after sending")
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

        // Create a second session if needed. On compact, the tap activates
        // the new session and collapses to the detail column, so re-reveal
        // the sidebar before checking the row count.
        if app.cells.count < 2 {
            newChatButton.tap()
            showSidebarIfNeeded(app: app)
            _ = app.cells.element(boundBy: 1).waitForExistence(timeout: 3)
        }

        guard app.cells.count >= 2 else {
            captureScreenshot(name: "Not-Enough-Sessions")
            XCTFail("Need at least 2 sessions for switching test")
            return
        }

        let firstSession = app.cells.element(boundBy: 0)
        firstSession.tap()
        captureScreenshot(name: "Switch-First-Session")

        showSidebarIfNeeded(app: app)

        let secondSession = app.cells.element(boundBy: 1)
        if secondSession.waitForExistence(timeout: 3) {
            secondSession.tap()
            captureScreenshot(name: "Switch-Second-Session")
        }
    }
}

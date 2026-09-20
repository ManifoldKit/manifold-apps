import XCTest

/// Drives the released ChatView message actions through the same context menu
/// available to a user: long press on iOS and secondary click on macOS.
///
/// Regenerate removes the last assistant message, then generates its
/// replacement. Editing a user message updates it, removes every later
/// message, and generates one new downstream assistant response. Each flow
/// keeps an earlier completed exchange in the transcript to prove that the
/// mutation is scoped to the selected turn rather than the whole session.
final class TurnLoopActionUITests: XCTestCase {
    private let earlierPrompt = "Keep this earlier prompt"
    private let earlierAnswer = "Earlier answer stays."
    private let originalPrompt = "Change this answer"
    private let editedPrompt = "Use this edited prompt"
    private let originalAnswer = "Original target answer."
    private let laterPrompt = "Discard this later prompt"
    private let laterAnswer = "Later answer to discard."
    private let replacementAnswer = "Replacement target answer."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRegenerateReplacesOnlyTheTargetAssistantAnswer() throws {
        let app = launchTurnLoopActionApp(additionalArgument: "--turn-loop-regeneration-test")
        seedTwoCompletedTurns(in: app)

        let originalAssistant = messageBubble(role: "Assistant", containing: originalAnswer, in: app)
        XCTAssertTrue(
            openMessageContextMenu(originalAssistant),
            "The completed target assistant message must expose the real message action menu"
        )
        XCTAssertTrue(
            tapMessageContextMenuAction(
                identifier: "message-action-regenerate",
                label: "Regenerate",
                in: app
            ),
            "The real assistant-message action menu must offer Regenerate"
        )

        XCTAssertEqual(
            waitForCompletedChatTurn(app: app, timeout: 10),
            "Response complete: \(replacementAnswer)",
            "Regenerate must produce the fixture's distinct replacement answer"
        )
        XCTAssertTrue(
            waitForElementToDisappear(originalAssistant, timeout: 5),
            "Regenerate must remove the original target assistant answer instead of appending another answer"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "User", containing: originalPrompt, in: app),
            1,
            "Regenerate must retain exactly one copy of its user prompt"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "Assistant", containing: replacementAnswer, in: app),
            1,
            "Regenerate must leave exactly one replacement assistant answer"
        )
        assertEarlierTurnIsUntouched(in: app)
    }

    func testEditUserMessageRewritesAllDownstreamHistory() throws {
        let app = launchTurnLoopActionApp(additionalArgument: "--turn-loop-edit-test")
        seedTwoCompletedTurns(in: app)
        send(laterPrompt, expecting: laterAnswer, in: app)

        let originalUser = messageBubble(role: "User", containing: originalPrompt, in: app)
        XCTAssertTrue(
            openMessageContextMenu(originalUser),
            "The target user message must expose the real message action menu"
        )
        XCTAssertTrue(
            tapMessageContextMenuAction(
                identifier: "message-action-edit",
                label: "Edit",
                in: app
            ),
            "The real user-message action menu must offer Edit"
        )

        let editor = app.textViews["message-edit-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "Edit must present the real message editor")
        editor.tap()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(editedPrompt)

        let save = app.buttons["message-edit-save"]
        XCTAssertTrue(
            save.waitForExistence(timeout: 3) && save.isEnabled,
            "The non-empty edited prompt must enable the real Save action"
        )
        save.tap()

        XCTAssertTrue(
            waitForElementToDisappear(originalUser, timeout: 5),
            "Saving an edit must replace the original user prompt in the transcript"
        )
        XCTAssertTrue(
            messageBubble(role: "User", containing: editedPrompt, in: app).waitForExistence(timeout: 5),
            "The edited user prompt must appear in the transcript"
        )
        XCTAssertEqual(
            waitForCompletedChatTurn(app: app, timeout: 10),
            "Response complete: \(replacementAnswer)",
            "Editing a user prompt must generate the fixture's downstream replacement answer"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "User", containing: editedPrompt, in: app),
            1,
            "Editing must leave one updated user prompt"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "Assistant", containing: replacementAnswer, in: app),
            1,
            "Editing must leave one regenerated downstream assistant answer"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "Assistant", containing: originalAnswer, in: app),
            0,
            "Editing a user prompt must remove the former downstream assistant answer"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "User", containing: laterPrompt, in: app),
            0,
            "Editing the middle user prompt must remove every later user message"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "Assistant", containing: laterAnswer, in: app),
            0,
            "Editing the middle user prompt must remove every later assistant message"
        )
        assertEarlierTurnIsUntouched(in: app)
    }

    private func launchTurnLoopActionApp(additionalArgument: String) -> XCUIApplication {
        let app = launchApp(additionalArguments: [additionalArgument])
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "The deterministic UI-test backend must leave the composer ready"
        )
        return app
    }

    private func seedTwoCompletedTurns(in app: XCUIApplication) {
        send(earlierPrompt, expecting: earlierAnswer, in: app)
        send(originalPrompt, expecting: originalAnswer, in: app)
    }

    private func send(_ prompt: String, expecting answer: String, in app: XCUIApplication) {
        guard let input = findMessageInput(app: app) else {
            XCTFail("Message input must exist before sending \(prompt)")
            return
        }
        tapMessageEditingArea(input)
        input.typeText(prompt)

        let send = app.buttons["Send message"]
        guard send.waitForExistence(timeout: 3), send.isEnabled else {
            XCTFail("Send must be enabled for \(prompt)")
            return
        }
        send.tap()
        XCTAssertEqual(
            waitForCompletedChatTurn(app: app, timeout: 10),
            "Response complete: \(answer)",
            "Sending \(prompt) must complete its deterministic turn"
        )
    }

    private func assertEarlierTurnIsUntouched(in app: XCUIApplication) {
        XCTAssertEqual(messageBubbleCount(role: "User", containing: earlierPrompt, in: app), 1)
        XCTAssertEqual(messageBubbleCount(role: "Assistant", containing: earlierAnswer, in: app), 1)
    }

    private func messageBubble(role: String, containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH[c] %@ AND label CONTAINS[c] %@",
                "\(role) said:",
                text
            )
        ).firstMatch
    }

    private func messageBubbleCount(role: String, containing text: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH[c] %@ AND label CONTAINS[c] %@",
                "\(role) said:",
                text
            )
        ).count
    }

    private func openMessageContextMenu(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5), element.isHittable else { return false }
        #if os(macOS)
        element.rightClick()
        #else
        element.press(forDuration: 1.2)
        #endif
        return true
    }

    private func tapMessageContextMenuAction(
        identifier: String,
        label: String,
        in app: XCUIApplication
    ) -> Bool {
        let candidates = [
            app.buttons[identifier],
            app.menuItems[identifier],
            app.buttons[label],
            app.menuItems[label],
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", identifier)
            ).firstMatch,
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 5) && candidate.isHittable {
            candidate.tap()
            return true
        }
        return false
    }

    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

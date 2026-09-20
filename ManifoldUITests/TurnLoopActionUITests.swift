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

    @MainActor
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

        XCTAssertTrue(
            waitForExpectedAnswer(replacementAnswer, in: app, timeout: 10),
            "Regenerate must produce the fixture's distinct replacement answer and complete the turn."
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

    @MainActor
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
        clickOrTap(editor)
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(editedPrompt)

        let save = app.buttons["message-edit-save"]
        XCTAssertTrue(
            save.waitForExistence(timeout: 3) && save.isEnabled,
            "The non-empty edited prompt must enable the real Save action"
        )
        clickOrTap(save)

        XCTAssertTrue(
            waitForElementToDisappear(originalUser, timeout: 5),
            "Saving an edit must replace the original user prompt in the transcript"
        )
        XCTAssertTrue(
            messageBubble(role: "User", containing: editedPrompt, in: app).waitForExistence(timeout: 5),
            "The edited user prompt must appear in the transcript"
        )
        XCTAssertTrue(
            waitForExpectedAnswer(replacementAnswer, in: app, timeout: 10),
            "Editing a user prompt must generate the fixture's downstream replacement answer and complete the turn."
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

    @MainActor
    private func launchTurnLoopActionApp(additionalArgument: String) -> XCUIApplication {
        let app = launchApp(additionalArguments: [additionalArgument])
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "The deterministic UI-test backend must leave the composer ready"
        )
        return app
    }

    @MainActor
    private func seedTwoCompletedTurns(in app: XCUIApplication) {
        send(earlierPrompt, expecting: earlierAnswer, in: app)
        send(originalPrompt, expecting: originalAnswer, in: app)
    }

    @MainActor
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
        clickOrTap(send)
        XCTAssertTrue(
            waitForExpectedAnswer(answer, in: app, timeout: 10),
            "Sending \(prompt) must complete its deterministic turn with the fixture's exact answer."
        )
    }

    @MainActor
    private func waitForExpectedAnswer(
        _ answer: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        #if os(macOS)
        // AppKit exposes chat-conversation as a Group without its SwiftUI
        // accessibility value. Match the exact visible assistant response and
        // require generation to have stopped instead of querying Other.
        let response = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Assistant said: \(answer)")
        ).firstMatch
        let completed = response.waitForExistence(timeout: timeout)
            && XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"),
                    object: app.buttons["Stop generation"]
                )],
                timeout: timeout
            ) == .completed
        #else
        let completed = waitForCompletedChatTurn(app: app, timeout: timeout)
            == "Response complete: \(answer)"
        #endif
        if !completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Expected answer missing or turn incomplete"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        return completed
    }

    @MainActor
    private func assertEarlierTurnIsUntouched(in app: XCUIApplication) {
        XCTAssertEqual(messageBubbleCount(role: "User", containing: earlierPrompt, in: app), 1)
        XCTAssertEqual(messageBubbleCount(role: "Assistant", containing: earlierAnswer, in: app), 1)
    }

    @MainActor
    private func messageBubble(role: String, containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH[c] %@ AND label CONTAINS[c] %@",
                "\(role) said:",
                text
            )
        ).firstMatch
    }

    @MainActor
    private func messageBubbleCount(role: String, containing text: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label BEGINSWITH[c] %@ AND label CONTAINS[c] %@",
                "\(role) said:",
                text
            )
        ).count
    }

    @MainActor
    private func openMessageContextMenu(_ element: XCUIElement) -> Bool {
        guard element.waitForExistence(timeout: 5), element.isHittable else { return false }
        #if os(macOS)
        // The centre of selectable message text opens AppKit's text-editing
        // menu (Ask Siri, Font, Spelling), hiding the message action menu.
        // Secondary-click the bubble's padded background, as a user can.
        let horizontalPosition: CGFloat = element.label.hasPrefix("User said:") ? 0.08 : 0.92
        element.coordinate(
            withNormalizedOffset: CGVector(dx: horizontalPosition, dy: 0.88)
        ).rightClick()
        #else
        element.press(forDuration: 1.2)
        #endif
        return true
    }

    @MainActor
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
            clickOrTap(candidate)
            return true
        }
        return false
    }

    @MainActor
    private func waitForElementToDisappear(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

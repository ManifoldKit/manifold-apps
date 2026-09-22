import XCTest

/// App-level coverage for the remaining turn-loop trust boundaries: a
/// cancelled stream must drain before the next send, and a branch must copy
/// history without letting branch-only messages leak back into its source.
final class CancelAndBranchUITests: XCTestCase {
    private let earlierPrompt = "Keep this earlier prompt"
    private let earlierAnswer = "Earlier answer stays."
    private let cancellationPrompt = "Start a cancellable response"
    private let cancelledPrefix =
        "Cancellation is in progress. This visible partial response is intentionally " +
        "long enough to flush through the real streaming buffer before Stop is pressed."
    private let cancelledStaleSuffix = "Stale output after Stop."
    private let recoveryPrompt = "Answer after cancellation"
    private let recoveryAnswer = "Recovery answer completed."
    private let branchSourcePrompt = "Create branch source history"
    private let branchSourceAnswer = "Branch source answer."
    private let branchOnlyPrompt = "Add this only to the branch"
    private let branchOnlyAnswer = "Branch-only answer."

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testStopCancelsStreamBeforeNextMessage() throws {
        let app = launchTurnLoopApp(argument: "--turn-loop-cancellation-test")
        typeAndSend(cancellationPrompt, in: app)

        let stop = app.buttons["Stop generation"]
        XCTAssertTrue(
            stop.waitForExistence(timeout: 5) && stop.isHittable,
            "An active deterministic stream must expose the real Stop control"
        )
        XCTAssertTrue(
            messageBubble(role: "Assistant", containing: cancelledPrefix, in: app)
                .waitForExistence(timeout: 5),
            "The cancellable stream must be visibly in progress before Stop is used"
        )
        clickOrTap(stop)

        XCTAssertTrue(
            waitForElementToDisappear(stop, timeout: 5),
            "The Stop control must disappear after cancellation drains"
        )
        #if !os(macOS)
        XCTAssertTrue(
            waitForChatTurnValue("Idle", app: app, timeout: 5),
            "Stop must return the conversation to idle within five seconds"
        )
        #endif
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 5),
            "The composer must accept a new turn after cancellation"
        )

        send(recoveryPrompt, expecting: recoveryAnswer, in: app)
        XCTAssertEqual(messageBubbleCount(role: "User", containing: recoveryPrompt, in: app), 1)
        XCTAssertEqual(messageBubbleCount(role: "Assistant", containing: recoveryAnswer, in: app), 1)
        XCTAssertEqual(
            messageBubbleCount(role: "Assistant", containing: cancelledPrefix, in: app),
            1,
            "The cancelled partial answer must remain one stable message after recovery"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "Assistant", containing: cancelledStaleSuffix, in: app),
            0,
            "The stream must reject the fixture's post-cancellation token attempt"
        )
    }

    @MainActor
    func testBranchKeepsSourceConversationUnchanged() throws {
        let app = launchTurnLoopApp(argument: "--turn-loop-branch-test")
        send(earlierPrompt, expecting: earlierAnswer, in: app)
        send(branchSourcePrompt, expecting: branchSourceAnswer, in: app)

        let branchPoint = messageBubble(role: "Assistant", containing: branchSourceAnswer, in: app)
        XCTAssertTrue(openMessageContextMenu(branchPoint), "The source answer must expose message actions")
        XCTAssertTrue(
            tapMessageContextMenuAction(
                identifier: "message-action-branch",
                label: "Branch from here",
                in: app
            ),
            "The real message menu must expose Branch from here"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["branch-origin-chip"].waitForExistence(timeout: 10),
            "Branching must navigate to the newly persisted conversation"
        )
        assertInheritedHistory(in: app)
        send(branchOnlyPrompt, expecting: branchOnlyAnswer, in: app)
        XCTAssertEqual(messageBubbleCount(role: "User", containing: branchOnlyPrompt, in: app), 1)
        XCTAssertEqual(messageBubbleCount(role: "Assistant", containing: branchOnlyAnswer, in: app), 1)

        XCTAssertTrue(
            selectSourceConversationByContent(in: app),
            "Selecting sidebar sessions must find the source transcript by its content"
        )
        assertInheritedHistory(in: app)
        XCTAssertEqual(
            messageBubbleCount(role: "User", containing: branchOnlyPrompt, in: app),
            0,
            "The branch-only user turn must not mutate the source conversation"
        )
        XCTAssertEqual(
            messageBubbleCount(role: "Assistant", containing: branchOnlyAnswer, in: app),
            0,
            "The branch-only answer must not mutate the source conversation"
        )
    }

    @MainActor
    private func launchTurnLoopApp(argument: String) -> XCUIApplication {
        let app = launchApp(additionalArguments: [argument])
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "The deterministic turn-loop backend must leave the composer ready"
        )
        return app
    }

    @MainActor
    private func typeAndSend(_ prompt: String, in app: XCUIApplication) {
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
    }

    @MainActor
    private func send(_ prompt: String, expecting answer: String, in app: XCUIApplication) {
        typeAndSend(prompt, in: app)
        XCTAssertTrue(
            waitForExpectedAnswer(answer, in: app, timeout: 10),
            "Sending \(prompt) must complete with the fixture's exact answer"
        )
    }

    @MainActor
    private func waitForExpectedAnswer(
        _ answer: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        #if os(macOS)
        let response = exactMessageBubble(role: "Assistant", text: answer, in: app)
        return response.waitForExistence(timeout: timeout)
            && waitForElementToDisappear(app.buttons["Stop generation"], timeout: timeout)
        #else
        return waitForCompletedChatTurn(app: app, timeout: timeout)
            == "Response complete: \(answer)"
        #endif
    }

    @MainActor
    private func assertInheritedHistory(in app: XCUIApplication) {
        XCTAssertEqual(messageBubbleCount(role: "User", containing: earlierPrompt, in: app), 1)
        XCTAssertEqual(messageBubbleCount(role: "Assistant", containing: earlierAnswer, in: app), 1)
        XCTAssertEqual(messageBubbleCount(role: "User", containing: branchSourcePrompt, in: app), 1)
        XCTAssertEqual(messageBubbleCount(role: "Assistant", containing: branchSourceAnswer, in: app), 1)
    }

    @MainActor
    private func selectSourceConversationByContent(in app: XCUIApplication) -> Bool {
        for index in 0..<4 {
            showSidebarIfNeeded(app: app)
            let rows = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == 'session-row'")
            )
            guard index < rows.count else { return false }

            let row = rows.element(boundBy: index)
            guard row.waitForExistence(timeout: 3) else { continue }
            if row.isHittable {
                clickOrTap(row)
            } else {
                clickOrTapCoordinate(row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            }
            openChatDetailIfNeeded(app: app)
            guard waitForChatInputReady(app: app, timeout: 5) else { continue }

            let sourceAnswer = messageBubble(role: "Assistant", containing: branchSourceAnswer, in: app)
            let branchOnly = messageBubble(role: "User", containing: branchOnlyPrompt, in: app)
            if sourceAnswer.waitForExistence(timeout: 5),
               waitForElementToDisappear(branchOnly, timeout: 2) {
                return true
            }
        }
        return false
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
    private func exactMessageBubble(role: String, text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "\(role) said: \(text)")
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

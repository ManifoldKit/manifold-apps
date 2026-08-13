import XCTest

/// Drives a real scripted tool call through the app's live ToolRegistry and
/// UIToolApprovalGate, then proves the approved result is paired back into the
/// transcript before the model's final response renders.
final class ToolsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp(additionalArguments: ["--tool-approval-test"])
    }

    func testApprovedWriteToolCompletesAndReturnsResult() throws {
        navigateToTools()

        let policyButton = app.buttons["tools-policy-button"]
        XCTAssertTrue(
            policyButton.waitForExistence(timeout: 5) && policyButton.isHittable,
            "Tools browser should expose the live approval-policy editor"
        )
        policyButton.tap()

        let policyTitle = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Tool Approval' OR value == 'Tool Approval'")
        ).firstMatch
        XCTAssertTrue(policyTitle.waitForExistence(timeout: 5), "Tool policy sheet should open")
        XCTAssertTrue(app.buttons["Always ask"].waitForExistence(timeout: 3), "Policy editor should expose Always ask")
        app.buttons["Always ask"].tap()
        app.buttons["tool-policy-done-button"].tap()

        // SwiftUI's lazy List does not materialize rows below the viewport
        // into the accessibility hierarchy. Scroll the live browser until
        // write_file's stable row identifier exists.
        let liveWriteTool = app.descendants(matching: .any)["tool-row-write_file"]
        let toolsBrowser = app.descendants(matching: .any)["tools-browser"]
        for _ in 0..<4 where !liveWriteTool.exists {
            toolsBrowser.swipeUp()
        }
        XCTAssertTrue(
            liveWriteTool.waitForExistence(timeout: 3),
            "Tools browser should read the registered write_file definition from the live registry"
        )

        navigateToChat()
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "The fixed scripted backend should make chat ready without a model load"
        )

        guard let input = findMessageInput(app: app) else {
            captureScreenshot(name: "Tools-No-Message-Input")
            XCTFail("Message input not found")
            return
        }
        input.tap()
        input.typeText("Write the approval result file")

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3) && sendButton.isEnabled, "Send should be enabled")
        sendButton.tap()

        let approvalTitle = app.descendants(matching: .any)["approval-sheet-title"]
        XCTAssertTrue(
            approvalTitle.waitForExistence(timeout: 10),
            "The scripted write_file call should suspend on UIToolApprovalGate and present approval UI"
        )
        let approveButton = app.buttons["approval-sheet-approve-button"]
        XCTAssertTrue(approveButton.exists && approveButton.isHittable, "Approval UI should expose a live Approve action")
        approveButton.tap()

        let completedInvocation = app.descendants(matching: .any)["tool-invocation-completed-write_file"]
        XCTAssertTrue(
            completedInvocation.waitForExistence(timeout: 10),
            "The approved executor result should pair with write_file as a completed tool invocation"
        )

        let finalReply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Tool write approved and completed'")
        ).firstMatch
        XCTAssertTrue(
            finalReply.waitForExistence(timeout: 10),
            "The turn loop should feed the ToolResult back to the backend and render its final answer"
        )

        captureScreenshot(name: "Tools-Approved-Completed")
    }

    private func navigateToTools() {
        showSidebarIfNeeded(app: app)
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Tools'"))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Sidebar should list Tools")
        row.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["tools-browser"].waitForExistence(timeout: 5),
            "Selecting Tools should open the live registry browser"
        )
    }

    private func navigateToChat() {
        showSidebarIfNeeded(app: app)
        let row = app.descendants(matching: .any)["chat-sidebar-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Sidebar should expose Chat")
        if row.isHittable {
            row.tap()
        } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        openChatDetailIfNeeded(app: app)
    }
}

import XCTest

/// Drives a real backend tool call through the app's live ToolRegistry and
/// UIToolApprovalGate, then proves the approved result is paired back into the
/// transcript before the model's final response renders.
final class ToolsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testApprovedWriteToolCompletesAndReturnsResult() throws {
        app = launchApp(additionalArguments: ["--tool-approval-test"])
        navigateToTools()
        assertAdvertisement("0 of 0 tools advertised")
        setSampleToolsEnabled(true)

        let advertisementSummary = app.descendants(matching: .any)["tool-advertisement-summary"]
        XCTAssertTrue(advertisementSummary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            advertisementSummary.label.contains("5 of 6 tools advertised"),
            "The Ollama-identity approval backend should receive the five-tool local catalog"
        )

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
            "The fixed history-aware backend should make chat ready without a model load"
        )

        guard let input = findMessageInput(app: app) else {
            captureScreenshot(name: "Tools-No-Message-Input")
            XCTFail("Message input not found")
            return
        }
        tapMessageEditingArea(input)
        input.typeText("Write the approval result file")

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3) && sendButton.isEnabled, "Send should be enabled")
        sendButton.tap()

        let approvalTitle = app.descendants(matching: .any)["approval-sheet-title"]
        XCTAssertTrue(
            approvalTitle.waitForExistence(timeout: 10),
            "The backend's write_file call should suspend on UIToolApprovalGate and present approval UI"
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
            NSPredicate(format: "label CONTAINS[c] 'Tool result history and exact file bytes verified.'")
        ).firstMatch
        XCTAssertTrue(
            finalReply.waitForExistence(timeout: 10),
            "The turn loop should feed the ToolResult back to the backend and render its final answer"
        )

        captureScreenshot(name: "Tools-Approved-Completed")
    }

    func testCloudBackendAdvertisesUsefulReferenceCatalogOnly() {
        app = launchApp(additionalArguments: ["--cloud-tool-catalog-test"])
        navigateToTools()
        assertAdvertisement("0 of 0 tools advertised")
        setSampleToolsEnabled(true)

        let advertisementSummary = app.descendants(matching: .any)["tool-advertisement-summary"]
        XCTAssertTrue(advertisementSummary.waitForExistence(timeout: 5))
        XCTAssertTrue(
            advertisementSummary.label.contains("6 of 6 tools advertised"),
            "OpenAI Responses should receive every useful reference tool"
        )

        XCTAssertFalse(
            app.descendants(matching: .any)["tool-row-fakeRateLimited"].exists,
            "Demo rate-limit fixtures must not be advertised to cloud models or shown to users"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["tool-row-fakeMCPLookup"].exists,
            "Demo MCP-failure fixtures must not be advertised to cloud models or shown to users"
        )
    }

    func testLateAppIntentRegistrationStaysAdvertisedWhenSamplesAreDisabled() {
        app = launchApp()
        navigateToTools()
        setSampleToolsEnabled(true)
        assertAdvertisement("5 of 6 tools advertised")

        XCTAssertTrue(tapFeatureSidebarRow("appintents", app: app))
        let register = app.buttons["appintent-tools-register-button"]
        XCTAssertTrue(register.waitForExistence(timeout: 5) && register.isHittable)
        register.tap()

        navigateToTools()
        assertAdvertisement("6 of 7 tools advertised")
        let intent = app.descendants(matching: .any)["tool-row-set_reminder_intent"]
        let browser = app.descendants(matching: .any)["tools-browser"]
        for _ in 0..<4 where !intent.exists { browser.swipeUp() }
        XCTAssertTrue(intent.waitForExistence(timeout: 3),
                      "The live advertised definitions must include a later AppIntent registration")
        let toggle = app.switches["sample-tools-enabled-toggle"]
        for _ in 0..<4 where !toggle.isHittable { browser.swipeDown() }
        setSampleToolsEnabled(false)
        assertAdvertisement("1 of 1 tools advertised")
        XCTAssertTrue(intent.waitForExistence(timeout: 3),
                      "Removing sample executors must retain the independent AppIntent definition")
    }

    func testSampleToolsAreOffAtLaunchAndRefuseForcedCalls() {
        verifyDisabledToolRefusal(afterEnabling: false)
    }

    func testDisablingSampleToolsRemovesTheirExecutors() {
        verifyDisabledToolRefusal(afterEnabling: true)
    }

    func testReenablingSampleToolsRequiresFreshApproval() {
        app = launchApp(additionalArguments: ["--tool-approval-test"])
        navigateToTools()
        setSampleToolsEnabled(true)
        navigateToChat()
        sendWriteAndApprove()

        navigateToTools()
        setSampleToolsEnabled(false)
        assertAdvertisement("0 of 0 tools advertised")
        setSampleToolsEnabled(true)
        navigateToChat()
        // The default once-per-session policy must ask again after disabling.
        sendWriteAndApprove()
    }

    private func verifyDisabledToolRefusal(afterEnabling: Bool) {
        app = launchApp(additionalArguments: ["--disabled-tool-call-test"])
        navigateToTools()
        assertAdvertisement("0 of 0 tools advertised")
        if afterEnabling {
            setSampleToolsEnabled(true)
            assertAdvertisement("5 of 6 tools advertised")
            setSampleToolsEnabled(false)
            assertAdvertisement("0 of 0 tools advertised")
        }
        navigateToChat()
        sendPrompt("Attempt the disabled write tool")
        let refused = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Disabled sample tool refused; no file was written.")
        ).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 15),
                      "The live dispatch must return unknownTool and leave the filesystem untouched")
        XCTAssertFalse(app.descendants(matching: .any)["approval-sheet-title"].exists,
                       "An unregistered sample tool must not request approval")
    }

    private func sendWriteAndApprove() {
        let replies = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Tool result history and exact file bytes verified.")
        )
        let previousReplies = replies.count
        sendPrompt("Write another approval result file")
        let approval = app.descendants(matching: .any)["approval-sheet-title"]
        XCTAssertTrue(approval.waitForExistence(timeout: 10), "A fresh explicit approval is required")
        app.buttons["approval-sheet-approve-button"].tap()
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                replies.count > previousReplies && !self.app.buttons["Stop generation"].exists
            }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 15), .completed,
                       "The new turn must finish with verified result history and file bytes")
    }

    private func sendPrompt(_ prompt: String) {
        guard let input = findMessageInput(app: app) else {
            XCTFail("Message input should be available")
            return
        }
        tapMessageEditingArea(input)
        input.typeText(prompt)
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled)
        send.tap()
    }

    private func setSampleToolsEnabled(_ enabled: Bool) {
        let toggle = app.switches["sample-tools-enabled-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5) && toggle.isHittable)
        XCTAssertEqual(toggle.value as? String, enabled ? "0" : "1", "Toggle must start in the opposite state")
        // SwiftUI exposes the entire row as the identified Switch. The
        // actual switch sits at its trailing edge; the row center is a label.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", enabled ? "1" : "0"), object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func assertAdvertisement(_ expected: String) {
        let summary = app.descendants(matching: .any)["tool-advertisement-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, expected)
    }

    private func navigateToTools() {
        XCTAssertTrue(
            tapFeatureSidebarRow("tools", app: app),
            "Sidebar should expose a selectable Tools row"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["tools-browser"].waitForExistence(timeout: 5),
            "Selecting Tools should open the live registry browser"
        )
    }

    private func navigateToChat() {
        XCTAssertTrue(
            tapFeatureSidebarRow("chat", app: app),
            "Sidebar should expose a selectable Chat row"
        )
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "Selecting Chat should restore the live chat detail"
        )
    }
}

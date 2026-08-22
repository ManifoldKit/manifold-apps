import XCTest

/// Mac-only coverage for companion-backed local-model wiring. The app swaps
/// MLX/GGUF loads for ScriptedBackend only under this explicit launch argument,
/// so the test exercises the production model-switcher and load dispatch
/// without downloading or allocating a real model.
final class MacLocalModelUITests: XCTestCase {
    private let mlxFixtureName = "Mac Fixture MLX"
    private let ggufFixtureName = "Mac Fixture GGUF"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp(additionalArguments: ["--mac-local-model-test"])
        openChatDetailIfNeeded(app: app)
    }

    @MainActor
    func testModelManagementButtonPresentsRealSheetAndTabPicker() throws {
        let button = app.descendants(matching: .any)["chat-model-management-button"]
        XCTAssertTrue(
            waitForHittable(button, timeout: 10),
            "The central chat model-management button should be reachable on Manifold Mac"
        )
        button.tap()

        // The sheet root is not consistently surfaced in macOS accessibility;
        // the tab picker is the real ModelManagementSheet content and is stable.
        XCTAssertTrue(
            app.descendants(matching: .any)["model-management-tab-picker"].waitForExistence(timeout: 5),
            "The real ModelManagementSheet tab picker should be visible on macOS"
        )
    }

    @MainActor
    func testFixtureRowsAreAvailableAndLoadThroughTheProductionSurface() throws {
        openModelSwitcher()

        let switcher = app.descendants(matching: .any)["model-switcher-list"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 5), "The model switcher should open")

        let mlxRow = descendant(in: switcher, containing: mlxFixtureName)
        let ggufRow = descendant(in: switcher, containing: ggufFixtureName)
        XCTAssertTrue(mlxRow.waitForExistence(timeout: 5), "The MLX fixture should be available")
        XCTAssertTrue(ggufRow.waitForExistence(timeout: 5), "The GGUF fixture should be available")

        let unavailableWarning = switcher.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'require' AND label CONTAINS[c] 'backend'")
        ).firstMatch
        XCTAssertFalse(unavailableWarning.exists, "Both fixtures should have registered local backends, not a missing-backend warning")

        loadAndAssertGeneration(row: mlxRow, model: mlxFixtureName, backend: "mlx", prompt: "fixture MLX turn")
        openModelSwitcher()
        loadAndAssertGeneration(
            row: descendant(in: app.descendants(matching: .any)["model-switcher-list"], containing: ggufFixtureName),
            model: ggufFixtureName,
            backend: "llama",
            prompt: "fixture GGUF turn"
        )
    }

    @MainActor
    private func openModelSwitcher() {
        let chipQuery = app.descendants(matching: .any).matching(
            identifier: "chat-model-switcher-chip"
        )
        if let chip = firstHittable(in: chipQuery, timeout: 3) {
            chip.tap()
            return
        }

        // macOS can move the principal toolbar item into the system More
        // overflow when the hosted window is crowded. Open that real toolbar
        // menu, then select the same identified chip from its menu hierarchy.
        let moreQuery = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'More' OR value CONTAINS[c] 'More'")
        )
        guard let more = firstHittable(in: moreQuery, timeout: 10) else {
            XCTFail("Manifold Mac ChatView model switcher is neither directly tappable nor reachable through the More toolbar overflow")
            return
        }
        more.tap()

        guard let overflowChip = firstHittable(in: chipQuery, timeout: 5) else {
            XCTFail("The More toolbar overflow should expose the identified model switcher chip")
            return
        }
        overflowChip.tap()
    }

    @MainActor
    private func loadAndAssertGeneration(row: XCUIElement, model: String, backend: String, prompt: String) {
        XCTAssertTrue(waitForHittable(row, timeout: 10), "Fixture row should be tappable: \(model)")
        row.tap()

        // The macOS switcher is a popover that remains open after selection.
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 10),
            "The composer should become ready after loading \(model)"
        )

        // A completed non-empty turn proves dispatchSelectedLoad installed the
        // selected backend; seeing the row or chip alone only proves selection.
        let activeChip = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'chat-model-switcher-chip' AND label CONTAINS[c] %@", model)
        ).firstMatch
        XCTAssertTrue(
            activeChip.waitForExistence(timeout: 5),
            "The switcher chip should identify active model \(model)"
        )

        let assistantCountBefore = assistantBubbles().count
        guard let input = findMessageInput(app: app) else {
            XCTFail("Message input should be available after loading \(model)")
            return
        }
        input.tap()
        input.typeText(prompt)

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(
            waitForEnabled(sendButton, timeout: 15),
            "Send should be enabled after loading \(model)"
        )
        sendButton.tap()

        XCTAssertTrue(waitForAssistantCount(toExceed: assistantCountBefore, timeout: 30), "A completed \(backend) turn should add an assistant bubble")
        guard let newestAssistant = assistantBubbles().last else {
            XCTFail("Assistant bubble count increased but no newest bubble could be queried")
            return
        }
        let label = newestAssistant.label.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            label,
            "Assistant said: Hello from the scripted UI-test backend.",
            "Each selection should install a fresh backend instance; a stale prior backend would advance to a different scripted turn"
        )
    }

    @MainActor
    private func assistantBubbles() -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Assistant said:'"))
            .allElementsBoundByIndex
    }

    @MainActor
    private func waitForAssistantCount(toExceed count: Int, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                (self?.assistantBubbles().count ?? 0) > count
            },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && element.isEnabled
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                return element.exists && element.isHittable
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func firstHittable(in query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                query.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            return nil
        }
        return query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable })
    }

    @MainActor
    private func descendant(in root: XCUIElement, containing text: String) -> XCUIElement {
        root.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        ).firstMatch
    }
}

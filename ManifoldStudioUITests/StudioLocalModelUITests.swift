import XCTest

/// Mac-only coverage for the companion-backed local-model wiring. The app
/// swaps MLX/GGUF loads for `ScriptedBackend` only under the explicit launch
/// argument, letting this target exercise RootView's real model-switcher and
/// load dispatch without downloading or allocating a real model.
final class StudioLocalModelUITests: XCTestCase {
    private let mlxFixtureName = "Studio Fixture MLX"
    private let ggufFixtureName = "Studio Fixture GGUF"

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp(additionalArguments: ["--studio-local-model-test"])
        openChatDetailIfNeeded(app: app)
    }

    @MainActor
    func testModelManagementButtonPresentsRealSheetAndTabPicker() throws {
        let button = app.descendants(matching: .any)["chat-model-management-button"]
        XCTAssertTrue(
            button.waitForExistence(timeout: 10) && button.isHittable,
            "The central chat model-management button should be reachable on Studio"
        )
        button.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["model-management-sheet"].waitForExistence(timeout: 5),
            "The host should present the real ModelManagementSheet"
        )
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
            NSPredicate(format: "label CONTAINS[c] 'require the' AND (label CONTAINS[c] 'MLX' OR label CONTAINS[c] 'GGUF')")
        ).firstMatch
        XCTAssertFalse(unavailableWarning.exists, "Both fixtures should have registered local backends, not a missing-backend warning")

        loadAndAssertDeviceInfo(row: mlxRow, model: mlxFixtureName, backend: "mlx")
        openModelSwitcher()
        loadAndAssertDeviceInfo(row: descendant(in: app.descendants(matching: .any)["model-switcher-list"], containing: ggufFixtureName), model: ggufFixtureName, backend: "llama")
    }

    @MainActor
    private func openModelSwitcher() {
        let chip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        XCTAssertTrue(
            chip.waitForExistence(timeout: 10) && chip.isHittable,
            "Studio ChatView should expose the host-owned model switcher"
        )
        chip.tap()
    }

    @MainActor
    private func loadAndAssertDeviceInfo(row: XCUIElement, model: String, backend: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 5) && row.isHittable, "Fixture row should be tappable: \(model)")
        row.tap()

        // ModelSwitcherView is a macOS popover, and a row selection does not
        // dismiss it. Close that presentation before opening the production
        // Device Info popover behind it.
        app.typeKey(.escape, modifierFlags: [])

        let deviceInfoButton = descendant(in: app, containing: "Device Info")
        XCTAssertTrue(
            deviceInfoButton.waitForExistence(timeout: 10) && deviceInfoButton.isHittable,
            "Device Info should be reachable after selecting \(model)"
        )
        deviceInfoButton.tap()

        // macOS commonly combines the popover's LabeledContent nodes. Query
        // all descendants by their exposed labels so this asserts the shipped
        // Device Info surface, not only the switcher selection state.
        XCTAssertTrue(
            descendant(in: app, containing: "Model Loaded").waitForExistence(timeout: 10),
            "Device Info should report Model Loaded"
        )
        XCTAssertTrue(
            descendant(in: app, containing: "Yes").waitForExistence(timeout: 10),
            "Device Info should report Model Loaded: Yes after dispatching \(model)"
        )
        XCTAssertTrue(
            descendant(in: app, containing: model).waitForExistence(timeout: 10),
            "Device Info should expose the active model after dispatching its load"
        )
        XCTAssertTrue(
            descendant(in: app, containing: backend).waitForExistence(timeout: 10),
            "Device Info should expose the active backend after dispatching its load"
        )
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    private func descendant(in root: XCUIElement, containing text: String) -> XCUIElement {
        root.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        ).firstMatch
    }
}

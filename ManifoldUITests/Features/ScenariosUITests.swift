import XCTest

final class ScenariosUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testQualificationScenarioRunsThroughTheLiveFeature() {
        app = launchApp(additionalArguments: [
            "--scenario-qualification-test",
            "--scenario", "structured-json-extraction",
        ])

        openQualificationFeature()
        app.buttons["qualification-run-button"].tap()

        let result = app.descendants(matching: .any)["qualification-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue(containing: "Passed", on: result, timeout: 15),
            "The package scenario runner should report the canonical scripted answer as passed"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["qualification-final-answer"]
                .waitForExistence(timeout: 5),
            "A completed qualification must expose the observed final answer"
        )
    }

    @MainActor
    func testQualificationFailureIsReportedRatherThanSilentlyPassing() {
        app = launchApp(additionalArguments: [
            "--scenario", "structured-json-extraction",
        ])

        openQualificationFeature()
        app.buttons["qualification-run-button"].tap()

        let result = app.descendants(matching: .any)["qualification-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue(containing: "Failed", on: result, timeout: 15),
            "An answer that violates the shared corpus assertions must be visibly reported as failed"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'missing' OR label CONTAINS[c] 'should'"))
                .firstMatch.waitForExistence(timeout: 5),
            "The failed run should retain its assertion evidence"
        )
    }

    @MainActor
    private func openQualificationFeature() {
        XCTAssertTrue(
            tapFeatureSidebarRow("scenarios", app: app),
            "The Scenarios feature should be reachable from the app sidebar"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["qualification-view"].waitForExistence(timeout: 10),
            "Selecting Scenarios should present the live qualification surface, not a placeholder"
        )
    }

    @MainActor
    private func waitForValue(containing expected: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", expected, expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

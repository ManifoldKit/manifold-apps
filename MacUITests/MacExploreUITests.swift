import XCTest

/// Mac coverage for Explore's native sidebar selection and the two host-owned
/// setup routes. `launchApp` provides the established macOS window recovery.
final class MacExploreUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp()
    }

    @MainActor
    func testExploreUsesNativeSetupRoutesAndResetsAppearance() throws {
        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        XCTAssertTrue(app.descendants(matching: .any)["explore-root"].waitForExistence(timeout: 5))

        let readout = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        let standard = readout.label
        captureScreenshot(name: "Mac-Explore-Component-Examples")
        let brand = app.buttons["Brand"]
        XCTAssertTrue(tapExploreElement(brand), "Brand must be reachable through the native Explore scroll path")
        XCTAssertNotEqual(readout.label, standard)
        captureScreenshot(name: "Mac-Explore-Brand-Theme")

        let reset = app.descendants(matching: .any)["theming-reset-button"]
        XCTAssertTrue(tapExploreElement(reset), "Reset must be reachable through the native Explore scroll path")
        XCTAssertEqual(readout.label, standard)

        let models = app.descendants(matching: .any)["explore-show-models"]
        XCTAssertTrue(tapExploreElement(models), "Models must be reachable through the native Explore scroll path")
        XCTAssertTrue(app.descendants(matching: .any)["model-management-tab-picker"].waitForExistence(timeout: 5))
        captureScreenshot(name: "Mac-Explore-Model-Management")
        dismissSheet(app: app)

        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        let cloud = app.descendants(matching: .any)["explore-show-cloud"]
        XCTAssertTrue(tapExploreElement(cloud), "Cloud providers must be reachable through the native Explore scroll path")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == 'Cloud APIs' OR value == 'Cloud APIs'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Cloud providers must open the existing API configuration surface on Mac"
        )
        captureScreenshot(name: "Mac-Explore-Cloud-Providers")
    }

    private func tapExploreElement(_ element: XCUIElement, maximumScrolls: Int = 4) -> Bool {
        let explore = app.descendants(matching: .any)["explore-root"]
        guard explore.waitForExistence(timeout: 5) else { return false }

        for _ in 0..<maximumScrolls {
            if element.exists && element.isHittable {
                element.tap()
                return true
            }
            explore.swipeUp()
        }

        if element.exists && element.isHittable {
            element.tap()
            return true
        }
        return false
    }
}

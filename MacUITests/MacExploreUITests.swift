import XCTest

/// Mac coverage for Explore's native sidebar selection and the two host-owned
/// setup routes. `launchApp` provides the established macOS window recovery.
final class MacExploreUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp()
    }

    func testExploreUsesNativeSetupRoutesAndResetsAppearance() throws {
        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        XCTAssertTrue(app.descendants(matching: .any)["explore-root"].waitForExistence(timeout: 5))

        let readout = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(readout.waitForExistence(timeout: 5))
        let standard = readout.label
        let brand = app.buttons["Brand"]
        XCTAssertTrue(brand.waitForExistence(timeout: 5))
        brand.tap()
        XCTAssertNotEqual(readout.label, standard)

        let reset = app.descendants(matching: .any)["theming-reset-button"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        XCTAssertEqual(readout.label, standard)

        let models = app.descendants(matching: .any)["explore-show-models"]
        XCTAssertTrue(models.waitForExistence(timeout: 5) && models.isHittable)
        models.tap()
        XCTAssertTrue(app.descendants(matching: .any)["model-management-tab-picker"].waitForExistence(timeout: 5))
        dismissSheet(app: app)

        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        let cloud = app.descendants(matching: .any)["explore-show-cloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 5) && cloud.isHittable)
        cloud.tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label == 'Cloud APIs' OR value == 'Cloud APIs'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Cloud providers must open the existing API configuration surface on Mac"
        )
    }
}

import XCTest

/// UI coverage for the Theming feature (manifold-apps W2 P6) — the preset
/// picker ported from ManifoldKit core's own
/// `Example/Advanced/DemoContentView.swift` onto `ThemingShowcaseView`.
///
/// Navigates from the sidebar to the feature, switches the preset picker
/// from Standard to Classic, and asserts a child reading the theme that
/// `RootView` actually installed sees the new value. This tests the global
/// write and the environment cascade, not merely that a tap registered.
/// The test then leaves and re-enters the feature to prove the app-owned
/// selection survives view reconstruction. Verified by
/// hand to fail when `ThemingFeature.makeView` is reverted to
/// `NotYetPortedView` (temporarily reverted, ran red, restored — see the PR
/// body for the transcript).
final class ThemingUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchApp()
    }

    func testSwitchingPresetChangesLivePreview() throws {
        navigateToTheming()

        let cornerRadiusLabel = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(
            waitForElement(cornerRadiusLabel, timeout: 5),
            "Theming showcase should render its live-preview corner-radius readout"
        )

        let initialValue = cornerRadiusLabel.label
        XCTAssertTrue(
            initialValue.contains("20pt"),
            "Standard preset (the initial selection) should read ManifoldTheme.standard's ChatTheme.cornerRadius (20pt), got: \(initialValue)"
        )

        let picker = app.descendants(matching: .any)["theming-preset-picker"]
        XCTAssertTrue(waitForElement(picker, timeout: 5), "Theming showcase should expose its preset picker")

        let classicOption = app.buttons["Classic"]
        XCTAssertTrue(waitForElement(classicOption, timeout: 5), "Preset picker should offer a Classic segment")
        classicOption.tap()

        let updatedLabel = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(
            waitForElement(updatedLabel, timeout: 5),
            "Theming showcase should keep its live-preview readout after changing presets"
        )
        let updatedValue = updatedLabel.label
        XCTAssertTrue(
            updatedValue.contains("16pt"),
            "Classic preset should read ManifoldTheme.classic's ChatTheme.cornerRadius (16pt), got: \(updatedValue)"
        )
        XCTAssertNotEqual(
            initialValue,
            updatedValue,
            "Switching presets must visibly change the live preview, not just register a tap"
        )

        showSidebarIfNeeded(app: app)
        let cloudRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Cloud'"))
            .firstMatch
        XCTAssertTrue(waitForElement(cloudRow, timeout: 5), "Sidebar should list a Cloud row")
        cloudRow.tap()

        navigateToTheming()

        let restoredLabel = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(
            waitForElement(restoredLabel, timeout: 5),
            "Theming showcase should restore its live-preview readout after reconstruction"
        )
        let restoredValue = restoredLabel.label
        XCTAssertTrue(
            restoredValue.contains("16pt"),
            "Classic must remain selected after the feature view is reconstructed, got: \(restoredValue)"
        )

        captureScreenshot(name: "Theming-Classic-Preset")
    }

    // MARK: - Navigation

    /// Reveals the sidebar (compact layouts hide it by default) and taps the
    /// "Theming" feature row to select `ThemingFeature` in `RootView`'s
    /// `NavigationSplitView` detail column.
    private func navigateToTheming() {
        showSidebarIfNeeded(app: app)

        let sidebarTitle = app.staticTexts["Chats"]
        XCTAssertTrue(
            waitForElement(sidebarTitle, timeout: 2),
            "Sidebar should remain visible while revealing the Theming row"
        )

        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Theming'"))
            .firstMatch
        XCTAssertTrue(waitForElement(row, timeout: 5), "Sidebar should list a Theming row")

        for _ in 0..<4 where !row.isHittable {
            XCTAssertTrue(sidebarTitle.exists, "Sidebar must remain visible while scrolling to Theming")
            app.swipeUp()
        }
        XCTAssertTrue(row.isHittable, "Theming row should become hittable after bounded sidebar scrolling")
        row.tap()

        let readout = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(
            waitForElement(readout, timeout: 5),
            "Tapping the Theming row should open the Theming detail"
        )
    }
}

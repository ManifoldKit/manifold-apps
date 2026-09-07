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

        let reset = app.descendants(matching: .any)["theming-reset-button"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "Theming should expose an explicit reset action")
        reset.tap()
        XCTAssertTrue(
            cornerRadiusLabel.label.contains("20pt"),
            "Reset appearance should restore the Standard preset through RootView's live theme cascade"
        )

        classicOption.tap()

        showSidebarIfNeeded(app: app)
        let selectedThemingRow = featureSidebarRow("theming", app: app)
        XCTAssertTrue(
            waitForElement(selectedThemingRow, timeout: 5) && selectedThemingRow.isSelected,
            "Reopened compact sidebar should expose Theming as the selected feature"
        )
        XCTAssertTrue(
            tapFeatureSidebarRow("cloud", app: app),
            "Sidebar should expose a selectable Cloud row"
        )
        let cloudTitle = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Cloud APIs' OR value == 'Cloud APIs'")
        ).firstMatch
        XCTAssertTrue(
            waitForElement(cloudTitle, timeout: 5),
            "Cloud selection must finish presenting the existing API configuration surface before reopening the sidebar"
        )

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
        let selectedTheming = tapFeatureSidebarRow("theming", app: app)
        if !selectedTheming {
            captureScreenshot(name: "Theming-Navigation-Failure")
            print("[Theming] failed to select Theming sidebar row:\n\(app.debugDescription)")
        }
        XCTAssertTrue(
            selectedTheming,
            "Theming row should become selectable after bounded feature-list scrolling"
        )

        let readout = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(
            waitForElement(readout, timeout: 5),
            "Tapping the Theming row should reveal its detail"
        )
    }
}

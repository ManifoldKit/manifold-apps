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
        let detailScrollView = requireThemingDetailScrollView()

        let cornerRadiusLabel = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(
            scrollUpUntilExists(cornerRadiusLabel, in: detailScrollView),
            "Theming showcase should render its live-preview corner-radius readout"
        )

        let initialValue = cornerRadiusLabel.label
        XCTAssertTrue(
            initialValue.contains("20pt"),
            "Standard preset (the initial selection) should read ManifoldTheme.standard's ChatTheme.cornerRadius (20pt), got: \(initialValue)"
        )

        let picker = app.descendants(matching: .any)["theming-preset-picker"]
        XCTAssertTrue(
            scrollDownUntilHittable(picker, in: detailScrollView),
            "Theming showcase should expose its preset picker"
        )

        let classicOption = app.buttons["Classic"]
        XCTAssertTrue(
            scrollDownUntilHittable(classicOption, in: detailScrollView),
            "Preset picker should offer a Classic segment"
        )
        classicOption.tap()

        let updatedLabel = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(
            scrollUpUntilExists(updatedLabel, in: detailScrollView),
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

        showSidebarIfNeeded(app: app)
        let themingRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Theming'"))
            .firstMatch
        XCTAssertTrue(waitForElement(themingRow, timeout: 5), "Sidebar should still list a Theming row")
        themingRow.tap()

        let restoredScrollView = requireThemingDetailScrollView()
        let restoredLabel = app.descendants(matching: .any)["theming-corner-radius-label"]
        XCTAssertTrue(
            scrollUpUntilExists(restoredLabel, in: restoredScrollView),
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

        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Theming'")).firstMatch
        XCTAssertTrue(waitForElement(row, timeout: 5), "Sidebar should list a Theming row")
        row.tap()
    }

    /// Finds the detail pane semantically without assigning an accessibility
    /// identifier to the container (which would hide its child identifiers).
    private func requireThemingDetailScrollView(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let scrollView = app.scrollViews
            .containing(.staticText, identifier: "Live preview")
            .firstMatch
        XCTAssertTrue(
            scrollView.waitForExistence(timeout: 5),
            "Theming detail should expose the ScrollView containing its Live preview heading",
            file: file,
            line: line
        )
        XCTAssertTrue(
            scrollView.isHittable,
            "Theming detail ScrollView should be hittable before scrolling",
            file: file,
            line: line
        )
        return scrollView
    }

    /// Compact CI devices do not expose descendants below the detail
    /// `ScrollView` viewport until that exact container has been scrolled.
    /// Keep the search bounded so a real missing readout still fails quickly.
    private func scrollUpUntilExists(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        maxSwipes: Int = 4
    ) -> Bool {
        if element.waitForExistence(timeout: 1) { return true }

        for _ in 0..<maxSwipes {
            scrollView.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return element.exists
    }

    /// Returns to controls above the preview after reading its lower content.
    private func scrollDownUntilHittable(
        _ element: XCUIElement,
        in scrollView: XCUIElement,
        maxSwipes: Int = 4
    ) -> Bool {
        if element.waitForExistence(timeout: 1), element.isHittable { return true }

        for _ in 0..<maxSwipes {
            scrollView.swipeDown()
            if element.waitForExistence(timeout: 1), element.isHittable { return true }
        }
        return element.exists && element.isHittable
    }
}

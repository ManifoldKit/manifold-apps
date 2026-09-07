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

        XCTAssertTrue(
            themeReadout(radius: 20).waitForExistence(timeout: 5),
            "Standard must render the live preview's 20pt bubble radius"
        )
        captureScreenshot(name: "Mac-Explore-Component-Examples")
        let brand = app.radioButtons["Brand"]
        XCTAssertTrue(tapExploreElement(brand), "Brand must be reachable through the native Explore scroll path")
        XCTAssertTrue(
            themeReadout(radius: 22).waitForExistence(timeout: 5),
            "Brand must render the live preview's 22pt bubble radius"
        )
        captureScreenshot(name: "Mac-Explore-Brand-Theme")

        let reset = app.descendants(matching: .any)["theming-reset-button"]
        XCTAssertTrue(tapExploreElement(reset), "Reset must be reachable through the native Explore scroll path")
        XCTAssertTrue(
            themeReadout(radius: 20).waitForExistence(timeout: 5),
            "Reset must restore the Standard live preview's 20pt bubble radius"
        )

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

    @MainActor
    private func tapExploreElement(_ element: XCUIElement, maximumScrolls: Int = 12) -> Bool {
        let explore = app.descendants(matching: .any)["explore-root"]
        guard explore.waitForExistence(timeout: 5) else { return false }

        for attempt in 0..<maximumScrolls {
            if element.exists && element.isHittable {
                element.tap()
                return true
            }

            guard element.exists else {
                logExploreGeometry(phase: "target unavailable before scroll \(attempt + 1)", explore: explore, target: element)
                break
            }

            let viewport = explore.frame
            let targetFrame = element.frame
            guard !viewport.isEmpty, !targetFrame.isEmpty else {
                logExploreGeometry(phase: "missing geometry before scroll \(attempt + 1)", explore: explore, target: element)
                break
            }

            if targetFrame.minY >= viewport.minY && targetFrame.maxY <= viewport.maxY {
                logExploreGeometry(phase: "target inside viewport \(attempt + 1)", explore: explore, target: element)
                if waitForHittable(element, timeout: 1) {
                    element.tap()
                    return true
                }
                break
            }

            let deltaY = targetFrame.minY < viewport.minY
                ? min(viewport.height / 3, 160)
                : -min(viewport.height / 3, 160)
            logExploreGeometry(phase: "before scroll \(attempt + 1)", explore: explore, target: element)
            captureScreenshot(name: "Mac-Explore-Before-Scroll-\(attempt + 1)")
            explore.scroll(byDeltaX: 0, deltaY: deltaY)
            logExploreGeometry(phase: "after scroll \(attempt + 1)", explore: explore, target: element)
            captureScreenshot(name: "Mac-Explore-After-Scroll-\(attempt + 1)")
        }

        if element.exists && element.isHittable {
            element.tap()
            return true
        }
        logExploreGeometry(phase: "failure", explore: explore, target: element)
        captureScreenshot(name: "Mac-Explore-Scroll-Failure")
        if explore.exists {
            print("[MacExplore] failure Explore AX tree:\n\(explore.debugDescription)")
        }
        if element.exists {
            print("[MacExplore] failure target AX tree:\n\(element.debugDescription)")
        }
        return false
    }

    @MainActor
    private func logExploreGeometry(phase: String, explore: XCUIElement, target: XCUIElement) {
        let exploreExists = explore.exists
        let targetExists = target.exists
        let exploreDescription = exploreExists ? "exists=true frame=\(explore.frame)" : "exists=false"
        let targetDescription = targetExists
            ? "exists=true hittable=\(target.isHittable) frame=\(target.frame)"
            : "exists=false"
        print("[MacExplore] \(phase): explore \(exploreDescription); target \(targetDescription)")
    }

    @MainActor
    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement, element.exists else { return false }
                return element.isHittable
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// XCTest preserves the SwiftUI identifier on the radius child. CUA's
    /// merged presentation is not the XCUITest accessibility hierarchy.
    @MainActor
    private func themeReadout(radius: Int) -> XCUIElement {
        let expected = "Bubble corner radius: \(radius)pt"
        return app.staticTexts.matching(
            NSPredicate(
                format: "identifier == %@ AND (value == %@ OR label == %@)",
                "theming-corner-radius-label",
                expected,
                expected
            )
        ).firstMatch
    }
}

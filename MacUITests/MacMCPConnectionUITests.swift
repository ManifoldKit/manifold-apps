import XCTest

/// Uses the production stdio transport and a process-backed fixture. The
/// published core currently cannot interoperate with an official newline-JSON
/// server, so this suite covers failure/retry truthfulness only. A successful
/// connection and connected-process shutdown test belong behind that core fix.
final class MacMCPConnectionUITests: XCTestCase {
    private let fixtureServerID = "3A1A1C87-5D4D-4B19-8C7E-78B36A6EEA72"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testUnavailableLocalServerShowsActionableFailureAndRetry() throws {
        let attemptLogURL = try makeAttemptLogURL()
        app = try launchFixtureApp(failing: true, attemptLogURL: attemptLogURL)
        XCTAssertTrue(tapFeatureSidebarRow("mcp", app: app))
        XCTAssertTrue(app.descendants(matching: .any)["mcp-connections-root"].waitForExistence(timeout: 5))

        connect()
        XCTAssertTrue(waitForStatus(prefix: "Failed", timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["mcp-service-error-\(fixtureServerID)"].waitForExistence(timeout: 3))
        let retry = app.descendants(matching: .any)["mcp-service-connect-\(fixtureServerID)"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3) && retry.label == "Retry" && retry.isEnabled)
        XCTAssertTrue(waitForFixtureEvents(["start", "exit"], count: 1, at: attemptLogURL))
        retry.tap()
        XCTAssertTrue(
            waitForFixtureEvents(["start", "exit"], count: 2, at: attemptLogURL),
            "Retry must launch a new local server process and each failed child must exit."
        )
        XCTAssertTrue(waitForStatus(prefix: "Failed", timeout: 8))
    }

    private func launchFixtureApp(failing: Bool, attemptLogURL: URL) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--mcp-connection-fixture", "-ApplePersistenceIgnoreState", "YES"]
        if failing { app.launchArguments.append("--mcp-connection-fixture-failure") }
        guard let fixtureURL = Bundle(for: Self.self).url(forResource: "mcp_stdio_fixture", withExtension: "py") else {
            XCTFail("The controlled MCP fixture must be present in the UI-test bundle.")
            throw FixtureError.missingBundleResource
        }
        app.launchEnvironment["MANIFOLD_MCP_FIXTURE_SERVER_PATH"] = fixtureURL.path
        app.launchEnvironment["MANIFOLD_MCP_FIXTURE_ATTEMPT_LOG"] = attemptLogURL.path
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.05)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        return app
    }

    private func makeAttemptLogURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-mcp-attempts-\(UUID().uuidString).log")
        try Data().write(to: url, options: .atomic)
        return url
    }

    private func waitForFixtureEvents(_ events: [String], count: Int, at url: URL) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let lines = (try? String(contentsOf: url, encoding: .utf8))?
                .split(separator: "\n")
                .map(String.init) ?? []
            if events.allSatisfy({ event in lines.filter { $0 == event }.count >= count }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func connect() {
        let button = app.descendants(matching: .any)["mcp-service-connect-\(fixtureServerID)"]
        XCTAssertTrue(button.waitForExistence(timeout: 3) && button.isHittable)
        button.tap()
        let consent = app.buttons["Connect"]
        if consent.waitForExistence(timeout: 1), consent.isHittable { consent.tap() }
    }

    @MainActor
    private var statusElement: XCUIElement {
        app.descendants(matching: .any)["mcp-service-status-\(fixtureServerID)"]
    }

    @MainActor
    private func waitForStatus(prefix: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prefix, prefix)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: statusElement)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private enum FixtureError: Error {
        case missingBundleResource
    }
}

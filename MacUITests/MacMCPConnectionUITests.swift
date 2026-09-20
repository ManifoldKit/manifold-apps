import XCTest

/// Uses the production stdio transport and a process-backed fixture. The
/// published core currently cannot interoperate with an official newline-JSON
/// server, so this suite covers failure/retry truthfulness only. A successful
/// connection and connected-process shutdown test belong behind that core fix.
final class MacMCPConnectionUITests: XCTestCase {
    private let fixtureServerID = "3A1A1C87-5D4D-4B19-8C7E-78B36A6EEA72"
    private var app: XCUIApplication!
    private let configurationTestStoreID = UUID().uuidString

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

    @MainActor
    func testInvalidLocalConfigurationIsRejectedAndValidServerPersists() throws {
        app = launchConfigurationApp(seedMalformed: false)
        openMCPFeature()
        let addLocal = app.buttons["Add Local Server"]
        XCTAssertTrue(addLocal.waitForExistence(timeout: 3) && addLocal.isEnabled)
        addLocal.tap()

        let name = app.textFields["Name"]
        let path = app.textFields["Executable path"]
        let add = app.buttons["Add"]
        XCTAssertTrue(name.waitForExistence(timeout: 3) && path.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Local fixture")
        path.tap()
        path.typeText("relative/server")
        add.tap()
        XCTAssertTrue(textElement("Enter an absolute executable path.").waitForExistence(timeout: 3))

        replaceText(in: path, with: "/bin/sh")
        add.tap()
        XCTAssertTrue(textElement("Shell executables are not allowed for MCP servers.").waitForExistence(timeout: 3))

        replaceText(in: path, with: "/usr/bin/python3")
        add.tap()
        XCTAssertTrue(textElement("Local fixture").waitForExistence(timeout: 3))

        app.terminate()
        app = launchConfigurationApp(seedMalformed: false)
        openMCPFeature()
        XCTAssertTrue(textElement("Local fixture").waitForExistence(timeout: 5),
                      "A valid local descriptor must survive an app relaunch in the isolated preferences suite.")
    }

    @MainActor
    func testMalformedSavedConfigurationStaysVisibleUntilExplicitReset() throws {
        app = launchConfigurationApp(seedMalformed: true)
        openMCPFeature()
        assertSavedConfigurationError()

        app.terminate()
        app = launchConfigurationApp(seedMalformed: false)
        openMCPFeature()
        assertSavedConfigurationError()

        let reset = app.descendants(matching: .any)["mcp-reset-saved-servers"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3) && reset.isHittable)
        reset.tap()
        let confirm = app.descendants(matching: .any)["mcp-confirm-reset-saved-servers"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3) && confirm.isHittable)
        confirm.tap()
        XCTAssertTrue(textElement("No local servers configured").waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Add Local Server"].isEnabled)

        app.terminate()
        app = launchConfigurationApp(seedMalformed: false)
        openMCPFeature()
        XCTAssertTrue(textElement("No local servers configured").waitForExistence(timeout: 5),
                      "Reset must persist instead of reviving the malformed data at next launch.")
    }

    @MainActor
    private func assertSavedConfigurationError() {
        XCTAssertTrue(textElement("Saved servers unavailable").waitForExistence(timeout: 5))
        XCTAssertTrue(textElement("Saved local server configurations could not be read. They were left unchanged. Reset saved servers to add new ones.").waitForExistence(timeout: 3))
        let addLocal = app.buttons["Add Local Server"]
        XCTAssertTrue(addLocal.waitForExistence(timeout: 3) && !addLocal.isEnabled,
                      "Unreadable saved data must not be overwritten by a new Add.")
    }

    @MainActor
    private func openMCPFeature() {
        XCTAssertTrue(tapFeatureSidebarRow("mcp", app: app))
        XCTAssertTrue(app.descendants(matching: .any)["mcp-connections-root"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func textElement(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with replacement: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(replacement)
    }

    @MainActor
    private func launchConfigurationApp(seedMalformed: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-ApplePersistenceIgnoreState", "YES"]
        if seedMalformed { app.launchArguments.append("--mcp-invalid-configuration-fixture") }
        app.launchEnvironment["MANIFOLD_MCP_CONFIG_TEST_STORE_ID"] = configurationTestStoreID
        activate(app)
        return app
    }

    @MainActor
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
        app.launchEnvironment["MANIFOLD_MCP_CONFIG_TEST_STORE_ID"] = configurationTestStoreID
        activate(app)
        return app
    }

    @MainActor
    private func activate(_ app: XCUIApplication) {
        app.launch()
        if !app.windows.firstMatch.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.05)).tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
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

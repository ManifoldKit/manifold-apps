import Darwin
import XCTest

/// Uses the production stdio transport and a process-backed fixture. The
/// success and lifecycle assertions pin behavior across the published core's
/// current newline-JSON interoperability and child-cleanup blockers.
final class MacMCPConnectionUITests: XCTestCase {
    private let fixtureServerID = "3A1A1C87-5D4D-4B19-8C7E-78B36A6EEA72"
    private var app: XCUIApplication!
    private var fixtureAttemptLogURL: URL?
    private var fixtureScriptPath: String?
    private let configurationTestStoreID = UUID().uuidString

    private enum FixtureMode: String {
        case success = "official-newline"
        case fail
        case stallInitialize = "stall-initialize"
        case cancelStall = "cancel-stall"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        defer {
            fixtureAttemptLogURL = nil
            fixtureScriptPath = nil
        }
        guard let fixtureAttemptLogURL else { return }
        // Test cleanup is recorded separately and happens only after assertions.
        // A leaked child cannot make an SDK-cleanup assertion pass.
        for pid in fixturePIDs(at: fixtureAttemptLogURL) where isOwnedFixtureProcess(pid) {
            recordFixtureTestEvent("test-cleanup:\(pid)", at: fixtureAttemptLogURL)
            _ = Darwin.kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline && isOwnedFixtureProcess(pid) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if isOwnedFixtureProcess(pid) {
                recordFixtureTestEvent("test-cleanup-force:\(pid)", at: fixtureAttemptLogURL)
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    @MainActor
    func testUnavailableLocalServerShowsActionableFailureAndRetry() throws {
        let attemptLogURL = try makeAttemptLogURL()
        app = try launchFixtureApp(mode: .fail, attemptLogURL: attemptLogURL)
        XCTAssertTrue(tapFeatureSidebarRow("mcp", app: app))
        XCTAssertTrue(app.descendants(matching: .any)["mcp-connections-root"].waitForExistence(timeout: 5))

        connect()
        XCTAssertTrue(waitForStatus(prefix: "Failed", timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["mcp-service-error-\(fixtureServerID)"].waitForExistence(timeout: 3))
        let retry = app.descendants(matching: .any)["mcp-service-connect-\(fixtureServerID)"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3) && retry.label == "Retry" && retry.isEnabled)
        XCTAssertTrue(waitForFixtureEvents(["start", "exit"], count: 1, at: attemptLogURL))
        retry.click()
        XCTAssertTrue(
            waitForFixtureEvents(["start", "exit"], count: 2, at: attemptLogURL),
            "Retry must launch a new local server process and each failed child must exit."
        )
        XCTAssertTrue(waitForStatus(prefix: "Failed", timeout: 8))
    }

    @MainActor
    func testOfficialNewlineServerConnectsOneToolAndDisconnectsEachChild() throws {
        let attemptLogURL = try makeAttemptLogURL()
        app = try launchFixtureApp(mode: .success, attemptLogURL: attemptLogURL)
        openMCPFeature()

        connect()
        let firstPID = try assertConnectedChild(at: attemptLogURL, attempt: 1)
        disconnect()
        XCTAssertTrue(waitForStatus(prefix: "Disconnected", timeout: 8))
        XCTAssertTrue(waitForFixtureExit(firstPID, at: attemptLogURL),
                      "Disconnect must close and reap the first live stdio child.")

        connect()
        let secondPID = try assertConnectedChild(at: attemptLogURL, attempt: 2)
        XCTAssertNotEqual(secondPID, firstPID, "Reconnect must start a distinct child process.")
        disconnect()
        XCTAssertTrue(waitForStatus(prefix: "Disconnected", timeout: 8))
        XCTAssertTrue(waitForFixtureExit(secondPID, at: attemptLogURL),
                      "Disconnect must close and reap the reconnected child.")
    }

    @MainActor
    func testInitializationTimeoutClosesStalledChild() throws {
        let attemptLogURL = try makeAttemptLogURL()
        app = try launchFixtureApp(mode: .stallInitialize, attemptLogURL: attemptLogURL)
        openMCPFeature()

        connect()
        XCTAssertTrue(waitForFixtureEvents(["start", "initialize"], count: 1, at: attemptLogURL))
        let pid = try XCTUnwrap(waitForFixturePID(at: attemptLogURL, attempt: 1))
        XCTAssertTrue(isOwnedFixtureProcess(pid), "Stalled initialization must have a live child.")
        XCTAssertTrue(waitForStatus(prefix: "Failed", timeout: 10))
        let error = app.descendants(matching: .any)["mcp-service-error-\(fixtureServerID)"]
        XCTAssertTrue(error.waitForExistence(timeout: 3) && error.label.contains("timed out"),
                      "A stalled initialize must report the initialization timeout.")
        XCTAssertTrue(waitForFixtureExit(pid, at: attemptLogURL),
                      "Initialization timeout must close and reap its child before Retry.")
    }

    @MainActor
    func testLeavingFeatureCancelsInitializationAndClosesChild() throws {
        let attemptLogURL = try makeAttemptLogURL()
        app = try launchFixtureApp(mode: .cancelStall, attemptLogURL: attemptLogURL)
        openMCPFeature()

        connect()
        XCTAssertTrue(waitForFixtureEvents(["start", "initialize"], count: 1, at: attemptLogURL))
        let pid = try XCTUnwrap(waitForFixturePID(at: attemptLogURL, attempt: 1))
        XCTAssertTrue(isOwnedFixtureProcess(pid))
        XCTAssertTrue(waitForStatus(prefix: "Connecting", timeout: 2),
                      "Navigate away while initialization is still in flight.")
        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        XCTAssertFalse(app.descendants(matching: .any)["mcp-connections-root"].exists)
        XCTAssertTrue(waitForFixtureExit(pid, at: attemptLogURL),
                      "Feature disappearance must cancel initialization and reap the child.")
        openMCPFeature()
        XCTAssertTrue(waitForStatus(prefix: "Disconnected", timeout: 5))
    }

    @MainActor
    func testFeatureDisappearanceClosesConnectedChild() throws {
        let attemptLogURL = try makeAttemptLogURL()
        app = try launchFixtureApp(mode: .success, attemptLogURL: attemptLogURL)
        openMCPFeature()

        connect()
        let featurePID = try assertConnectedChild(at: attemptLogURL, attempt: 1)
        XCTAssertTrue(tapFeatureSidebarRow("explore", app: app))
        XCTAssertTrue(waitForFixtureExit(featurePID, at: attemptLogURL),
                      "Leaving MCP must close an established connection.")
    }

    @MainActor
    func testBackgroundShutdownClosesConnectedChild() throws {
        let attemptLogURL = try makeAttemptLogURL()
        app = try launchFixtureApp(mode: .success, attemptLogURL: attemptLogURL)
        openMCPFeature()

        connect()
        let backgroundPID = try assertConnectedChild(at: attemptLogURL, attempt: 1)
        app.typeKey("h", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5),
                      "Hiding the app must enter the background scene phase.")
        XCTAssertTrue(waitForFixtureExit(backgroundPID, at: attemptLogURL),
                      "Background shutdown must close an established stdio child.")
        app.activate()
        XCTAssertTrue(waitForStatus(prefix: "Disconnected", timeout: 5))
    }

    @MainActor
    func testUnexpectedEOFAfterToolListShowsFailureAndReapsChild() throws {
        let attemptLogURL = try makeAttemptLogURL()
        app = try launchFixtureApp(mode: .success, attemptLogURL: attemptLogURL)
        openMCPFeature()

        connect()
        let pid = try assertConnectedChild(at: attemptLogURL, attempt: 1)
        // Close only this verified test-owned child after Connected is visible.
        // The app did not request a disconnect, so EOF must surface as failure.
        recordFixtureTestEvent("test-triggered-eof:\(pid)", at: attemptLogURL)
        XCTAssertEqual(Darwin.kill(pid, SIGTERM), 0)
        XCTAssertTrue(waitForStatus(prefix: "Failed", timeout: 10),
                      "Unexpected EOF after a connected tool list must not appear disconnected or healthy.")
        let error = app.descendants(matching: .any)["mcp-service-error-\(fixtureServerID)"]
        XCTAssertTrue(error.waitForExistence(timeout: 3) && error.label.contains("closed"),
                      "Unexpected EOF must explain that the server closed its connection.")
        let retry = app.descendants(matching: .any)["mcp-service-connect-\(fixtureServerID)"]
        XCTAssertTrue(retry.waitForExistence(timeout: 3) && retry.label == "Retry" && retry.isEnabled)
        XCTAssertTrue(waitForFixtureExit(pid, at: attemptLogURL))
    }

    @MainActor
    func testInvalidLocalConfigurationIsRejectedAndValidServerPersists() throws {
        app = launchConfigurationApp(seedMalformed: false)
        openMCPFeature()
        let addLocal = app.buttons["Add Local Server"]
        XCTAssertTrue(addLocal.waitForExistence(timeout: 3) && addLocal.isEnabled)
        addLocal.click()

        let name = app.textFields["Name"]
        let path = app.textFields["Executable path"]
        let add = app.buttons["Add"]
        XCTAssertTrue(name.waitForExistence(timeout: 3) && path.waitForExistence(timeout: 3))
        name.click()
        name.typeText("Local fixture")
        path.click()
        path.typeText("relative/server")
        add.click()
        XCTAssertTrue(textElement("Enter an absolute executable path.").waitForExistence(timeout: 3))

        replaceText(in: path, with: "/bin/sh")
        add.click()
        XCTAssertTrue(textElement("Shell executables are not allowed for MCP servers.").waitForExistence(timeout: 3))

        replaceText(in: path, with: "/usr/bin/python3")
        add.click()
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
        reset.click()
        let confirm = app.descendants(matching: .any)["mcp-confirm-reset-saved-servers"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3) && confirm.isHittable)
        confirm.click()
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
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", label, label))
            .firstMatch
    }

    @MainActor
    private func replaceText(in field: XCUIElement, with replacement: String) {
        field.click()
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
    private func launchFixtureApp(mode: FixtureMode, attemptLogURL: URL) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--mcp-connection-fixture", "-ApplePersistenceIgnoreState", "YES"]
        if mode == .fail { app.launchArguments.append("--mcp-connection-fixture-failure") }
        guard let fixtureURL = Bundle(for: Self.self).url(forResource: "mcp_stdio_fixture", withExtension: "py") else {
            XCTFail("The controlled MCP fixture must be present in the UI-test bundle.")
            throw FixtureError.missingBundleResource
        }
        app.launchEnvironment["MANIFOLD_MCP_FIXTURE_SERVER_PATH"] = fixtureURL.path
        app.launchEnvironment["MANIFOLD_MCP_FIXTURE_ATTEMPT_LOG"] = attemptLogURL.path
        app.launchEnvironment["MANIFOLD_MCP_FIXTURE_MODE"] = mode.rawValue
        app.launchEnvironment["MANIFOLD_MCP_CONFIG_TEST_STORE_ID"] = configurationTestStoreID
        fixtureAttemptLogURL = attemptLogURL
        fixtureScriptPath = fixtureURL.path
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
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.05)).click()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    private func makeAttemptLogURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-mcp-attempts-\(UUID().uuidString).log")
        try Data().write(to: url, options: .atomic)
        return url
    }

    private func waitForFixtureEvents(_ events: [String], count: Int, at url: URL) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let lines = fixtureEvents(at: url)
            if events.allSatisfy({ event in lines.filter { $0 == event }.count >= count }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func fixtureEvents(at url: URL) -> [String] {
        (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n")
            .map(String.init) ?? []
    }

    private func fixturePIDs(at url: URL) -> [Int32] {
        fixtureEvents(at: url).compactMap { line in
            guard line.hasPrefix("pid:") else { return nil }
            return Int32(line.dropFirst("pid:".count))
        }
    }

    private func waitForFixturePID(at url: URL, attempt: Int) -> Int32? {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let pids = fixturePIDs(at: url)
            if pids.count >= attempt { return pids[attempt - 1] }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return nil
    }

    private func isOwnedFixtureProcess(_ pid: Int32) -> Bool {
        guard Darwin.kill(pid, 0) == 0, let fixtureScriptPath else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/ps")
        probe.arguments = ["-ww", "-p", String(pid), "-o", "command="]
        let output = Pipe()
        probe.standardOutput = output
        probe.standardError = Pipe()
        do {
            try probe.run()
            probe.waitUntilExit()
            guard probe.terminationStatus == 0 else { return false }
            let command = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return command.contains(fixtureScriptPath)
        } catch {
            return false
        }
    }

    private func waitForFixtureExit(_ pid: Int32, at url: URL) -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if fixtureEvents(at: url).contains("exit-pid:\(pid)") && isProcessReaped(pid) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func isProcessReaped(_ pid: Int32) -> Bool {
        // A zombie is still present in the process table even if `ps` prints
        // <defunct> instead of the fixture command. Permission/probe errors
        // must not be mistaken for a successfully reaped child either.
        if Darwin.kill(pid, 0) == 0 { return false }
        return errno == ESRCH
    }

    private func recordFixtureTestEvent(_ event: String, at url: URL) {
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(event)\n".utf8))
            try handle.close()
        } catch {
            XCTFail("Could not record fixture test cleanup: \(error)")
        }
    }

    @MainActor
    private func assertConnectedChild(at url: URL, attempt: Int) throws -> Int32 {
        XCTAssertTrue(waitForStatus(prefix: "Connected · 1 tool available", timeout: 10),
                      "A successful initialize and tools/list must expose exactly one tool.")
        XCTAssertTrue(waitForFixtureEvents(["start", "initialize", "tools/list"], count: attempt, at: url))
        let pid = try XCTUnwrap(waitForFixturePID(at: url, attempt: attempt))
        XCTAssertTrue(isOwnedFixtureProcess(pid), "Connected must retain a live stdio child.")
        XCTAssertFalse(fixtureEvents(at: url).contains("exit-pid:\(pid)"))
        return pid
    }

    @MainActor
    private func connect() {
        let button = app.descendants(matching: .any)["mcp-service-connect-\(fixtureServerID)"]
        XCTAssertTrue(button.waitForExistence(timeout: 3) && button.isHittable)
        button.click()
        let consent = app.buttons["Connect"]
        if consent.waitForExistence(timeout: 1), consent.isHittable { consent.click() }
    }

    @MainActor
    private func disconnect() {
        let button = app.descendants(matching: .any)["mcp-service-disconnect-\(fixtureServerID)"]
        XCTAssertTrue(button.waitForExistence(timeout: 3) && button.isHittable)
        button.click()
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

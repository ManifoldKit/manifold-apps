import XCTest

/// Physical-device release coverage for the production Foundation Models
/// bootstrap. Unlike the ordinary UI suite, this test never substitutes a
/// scripted backend: a fresh store must discover, load, and generate through
/// the OS-resident model before the build is eligible for TestFlight.
final class FoundationDeviceUITests: XCTestCase {
    @MainActor
    func testFreshInstallLoadsFoundationAndCompletesRealTurn() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real Foundation Models validation requires a physical iOS device.")
        #else
        continueAfterFailure = false
        let app = launchApp(additionalArguments: ["--ios-real-foundation-test"])
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 120),
            "Production bootstrap must load Foundation Models on this release device; a scripted backend is forbidden in this gate."
        )

        guard let input = findMessageInput(app: app) else {
            XCTFail("Message input must be available after Foundation loads.")
            return
        }
        input.tap()
        input.typeText("Reply with a short greeting. Do not use tools.")

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 5) && sendButton.isEnabled,
            "Send must become available after entering the real-device prompt."
        )
        sendButton.tap()

        let responsePrefix = "Response complete:"
        let completion = waitForCompletedChatTurn(app: app, timeout: 180) ?? ""
        XCTAssertGreaterThan(
            completion.trimmingCharacters(in: .whitespacesAndNewlines).count,
            responsePrefix.count,
            "The live Foundation response must contain generated text."
        )
        #endif
    }
}

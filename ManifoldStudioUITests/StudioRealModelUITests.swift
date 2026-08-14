import Foundation
import XCTest

/// Opt-in physical-hardware coverage for the Studio local backend wiring.
///
/// The normal Studio UI target still runs the deterministic fixture test. This
/// test is deliberately skipped unless the real-model scheme setting expands
/// `MANIFOLD_STUDIO_REAL_MODEL_TEST=1`; when enabled, one app process loads
/// the installed MLX model, a real GGUF, then MLX again and completes a turn
/// after each switch.
final class StudioRealModelUITests: XCTestCase {
    private static let optInEnvironmentKey = "MANIFOLD_STUDIO_REAL_MODEL_TEST"
    private static let mlxPathEnvironmentKey = "MANIFOLD_STUDIO_REAL_MLX_MODEL_PATH"
    private static let ggufPathEnvironmentKey = "MANIFOLD_STUDIO_REAL_GGUF_MODEL_PATH"
    private static let mlxBytesEnvironmentKey = "MANIFOLD_STUDIO_REAL_MLX_MODEL_BYTES"
    private static let ggufBytesEnvironmentKey = "MANIFOLD_STUDIO_REAL_GGUF_MODEL_BYTES"
    private static let defaultMLXModelPath = "~/Documents/Models/mlx/Qwen3.5-2B-4bit"
    private static let defaultGGUFModelPath = "~/Documents/Models/gguf/Qwen3.5-2B/Qwen_Qwen3.5-2B-Q4_K_M.gguf"

    private var app: XCUIApplication!

    private var mlxModelName: String {
        displayName(for: realModelPath(for: Self.mlxPathEnvironmentKey, defaultPath: Self.defaultMLXModelPath))
    }

    private var ggufModelName: String {
        displayName(for: realModelPath(for: Self.ggufPathEnvironmentKey, defaultPath: Self.defaultGGUFModelPath))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Studio real-model hardware gate is opt-in. Run scripts/test-studio-real-models.sh or make studio-real-models on an arm64 Mac with the required models."
            )
        }

        app = XCUIApplication()
        // Keep persistence isolated between gate runs. AppEnvironment treats
        // the real-model argument as authoritative for inference wiring, so
        // --uitesting cannot choose ScriptedBackend or its fixture catalogue.
        app.launchArguments = ["--uitesting", "--studio-real-model-test"]
        app.launchEnvironment[Self.optInEnvironmentKey] = "1"
        for key in [
            Self.mlxPathEnvironmentKey,
            Self.ggufPathEnvironmentKey,
            Self.mlxBytesEnvironmentKey,
            Self.ggufBytesEnvironmentKey
        ] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Studio should reach the foreground for the real-model gate")
        openChatDetailIfNeeded(app: app)
    }

    @MainActor
    func testLiveMLXToGGUFToMLXSwitchesAndGenerates() throws {
        loadVerifyAndGenerate(
            model: mlxModelName,
            backend: "mlx",
            prompt: "Reply with exactly: MLX one. Do not call tools or use tools."
        )
        loadVerifyAndGenerate(
            model: ggufModelName,
            backend: "llama",
            prompt: "Reply with exactly: GGUF one. Do not call tools or use tools."
        )
        loadVerifyAndGenerate(
            model: mlxModelName,
            backend: "mlx",
            prompt: "Reply with exactly: MLX two. Do not call tools or use tools."
        )
    }

    @MainActor
    private func loadVerifyAndGenerate(model: String, backend: String, prompt: String) {
        openModelSwitcher()
        let switcher = app.descendants(matching: .any)["model-switcher-list"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "Model switcher should open before selecting \(model)")

        let row = descendant(in: switcher, containing: model)
        XCTAssertTrue(
            row.waitForExistence(timeout: 15) && row.isHittable,
            "The discovered installed model should be selectable: \(model)"
        )
        row.tap()

        // The macOS switcher is a popover that stays open after selection.
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 300),
            "Composer should become ready only after the real \(backend) model load completes"
        )
        assertSelectedModelChip(model: model, backend: backend)

        let assistantCountBefore = assistantBubbles().count
        guard let input = findMessageInput(app: app) else {
            XCTFail("Message input should be available after loading \(model)")
            return
        }
        input.tap()
        input.typeText(prompt)

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 5) && sendButton.isEnabled,
            "Send should be enabled after typing a prompt for \(model)"
        )
        sendButton.tap()

        XCTAssertTrue(
            waitForGenerationToStartAndFinishWithoutApproval(timeout: 180),
            "The real \(backend) turn should finish without requesting an arbitrary tool call"
        )

        XCTAssertTrue(
            waitForNonEmptyAssistant(afterCount: assistantCountBefore, timeout: 180),
            "A real \(backend) turn should add an assistant bubble containing generated text"
        )
        guard let newestAssistant = assistantBubbles().last else {
            XCTFail("Assistant bubble count increased but no newest bubble could be queried")
            return
        }
        let label = newestAssistant.label.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(
            label.hasPrefix("Assistant said:") && label.count > "Assistant said:".count,
            "The newest assistant bubble must contain generated text, not only an empty assistant record: \(label)"
        )
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "Composer should return to an enabled, hittable state after the real \(backend) turn completes"
        )
    }

    @MainActor
    private func openModelSwitcher() {
        let chip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        XCTAssertTrue(
            chip.waitForExistence(timeout: 180) && chip.isHittable,
            "Studio ChatView should expose its host-owned model switcher after real model discovery"
        )
        chip.tap()
    }

    @MainActor
    private func waitForGenerationToStartAndFinishWithoutApproval(timeout: TimeInterval) -> Bool {
        let stop = app.buttons["Stop generation"]
        guard stop.waitForExistence(timeout: 30) else { return false }
        let approval = app.descendants(matching: .any)["approval-sheet-title"]
        let terminal = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                approval.exists || !stop.exists
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [terminal], timeout: timeout) == .completed else {
            return false
        }
        return !approval.exists && !stop.exists
    }

    @MainActor
    private func assertSelectedModelChip(model: String, backend: String) {
        let modelChip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        XCTAssertTrue(
            modelChip.waitForExistence(timeout: 15) && modelChip.isHittable,
            "The model switcher chip should remain available after loading \(model)"
        )
        let chipLabel = modelChip.label
        XCTAssertTrue(
            chipLabel.localizedCaseInsensitiveContains(model),
            "The selected model chip should identify \(model), got: \(chipLabel)"
        )
        // The model's registry identity selects the backend family; completion
        // below then proves that this selected backend really generated a turn.
        XCTAssertFalse(chipLabel.isEmpty, "The selected \(backend) model chip should have an accessible identity")
    }

    @MainActor
    private func assistantBubbles() -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] 'Assistant said:'"))
            .allElementsBoundByIndex
    }

    @MainActor
    private func waitForNonEmptyAssistant(afterCount count: Int, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                let bubbles = self.assistantBubbles()
                guard bubbles.count > count, let newest = bubbles.last else { return false }
                let prefix = "Assistant said:"
                let label = newest.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return label.hasPrefix(prefix) && label.count > prefix.count
            },
            object: nil
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func descendant(in root: XCUIElement, containing text: String) -> XCUIElement {
        root.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", text, text)
        ).firstMatch
    }

    private func realModelPath(for environmentKey: String, defaultPath: String) -> String {
        let rawPath = ProcessInfo.processInfo.environment[environmentKey] ?? defaultPath
        return (rawPath as NSString).expandingTildeInPath
    }

    private func displayName(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let rawName: String
        if url.pathExtension.lowercased() == "gguf" {
            rawName = (url.lastPathComponent as NSString).deletingPathExtension
        } else {
            // MLX directories legitimately contain dots in names such as
            // `Qwen3.5-2B-4bit`; unlike a GGUF filename, that is not an
            // extension to strip before matching ModelInfo.name.
            rawName = url.lastPathComponent
        }
        return rawName
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

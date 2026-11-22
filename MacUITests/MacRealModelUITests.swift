import Foundation
import XCTest

/// Opt-in physical-hardware coverage for the Manifold Mac local backend wiring.
///
/// The normal Manifold Mac UI target still runs its deterministic fixtures.
/// `MANIFOLD_MAC_REAL_MODEL_TEST=1` enables installed-model switching,
/// cancellation, image recall, and same-chat resend through native controls.
final class MacRealModelUITests: XCTestCase {
    private static let optInEnvironmentKey = "MANIFOLD_MAC_REAL_MODEL_TEST"
    private static let mlxPathEnvironmentKey = "MANIFOLD_MAC_REAL_MLX_MODEL_PATH"
    private static let ggufPathEnvironmentKey = "MANIFOLD_MAC_REAL_GGUF_MODEL_PATH"
    private static let mlxBytesEnvironmentKey = "MANIFOLD_MAC_REAL_MLX_MODEL_BYTES"
    private static let ggufBytesEnvironmentKey = "MANIFOLD_MAC_REAL_GGUF_MODEL_BYTES"
    private static let qwenPathEnvironmentKey = "MANIFOLD_MAC_REAL_QWEN_MODEL_PATH"
    private static let qwenBytesEnvironmentKey = "MANIFOLD_MAC_REAL_QWEN_MODEL_BYTES"
    private static let defaultMLXModelPath = "~/Documents/Models/mlx/Qwen3.5-2B-4bit"
    private static let defaultGGUFModelPath = "~/Documents/Models/gguf/Qwen3.5-2B/Qwen_Qwen3.5-2B-Q4_K_M.gguf"
    private static let maximumEarlyStopAttempts = 2
    // Native macOS XCTest exposes at most this many characters of a message label.
    // The composer exposes the full text and is checked before submitting it.
    private static let transcriptLabelLimit = 512

    private var app: XCUIApplication!

    private var mlxModelName: String {
        displayName(for: realModelPath(for: Self.mlxPathEnvironmentKey, defaultPath: Self.defaultMLXModelPath))
    }

    private var ggufModelName: String {
        displayName(
            for: realModelPath(for: Self.ggufPathEnvironmentKey, defaultPath: Self.defaultGGUFModelPath),
            strippingExtension: true
        )
    }

    @MainActor
    private var qwenModelName: String {
        get throws {
            let path = try XCTUnwrap(
                app.launchEnvironment[Self.qwenPathEnvironmentKey],
                "Run make mac-real-models to stage the installed Qwen model"
            )
            return displayName(for: path)
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment[Self.optInEnvironmentKey] == "1" else {
            throw XCTSkip(
                "Manifold Mac real-model hardware gate is opt-in. Run scripts/test-mac-real-models.sh or make mac-real-models on an arm64 Mac with the required models."
            )
        }

        app = XCUIApplication()
        // Keep persistence isolated between gate runs. AppEnvironment treats
        // the real-model argument as authoritative for inference wiring, so
        // --uitesting cannot choose ScriptedBackend or its fixture catalogue.
        app.launchArguments = ["--uitesting", "--mac-real-model-test"]
        app.launchEnvironment[Self.optInEnvironmentKey] = "1"
        for key in [
            Self.mlxPathEnvironmentKey,
            Self.ggufPathEnvironmentKey,
            Self.mlxBytesEnvironmentKey,
            Self.ggufBytesEnvironmentKey,
            Self.qwenPathEnvironmentKey,
            Self.qwenBytesEnvironmentKey,
        ] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Manifold Mac should reach the foreground for the real-model gate")
        openChatDetailIfNeeded(app: app)
    }

    @MainActor
    func testLiveMLXToGGUFToMLXSwitchesAndGenerates() throws {
        XCTAssertNotEqual(
            mlxModelName.localizedLowercase,
            ggufModelName.localizedLowercase,
            "MLX and GGUF model rows must have distinct display identities"
        )
        let composer = app.textFields["Message input"]
        XCTAssertFalse(composer.exists && composer.isEnabled, "The isolated launch must start without a loaded model")
        selectModel(try qwenModelName, backend: "mlx")
        XCTAssertFalse(hasTurnFailure(), "The staged Qwen MLX model must load without errors")

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
    func testLiveMLXRetainsImageFromEarlierTurnAfterEarlyStop() throws {
        try verifyImageRecallAfterEarlyStop(
            card: "card-1", identifier: "Site Q7", expectedColor: "red", attachToStoppedTurn: false
        )
    }

    @MainActor
    func testLiveMLXRetainsImageInStoppedTurnAfterEarlyStop() throws {
        try verifyImageRecallAfterEarlyStop(
            card: "card-2", identifier: "Site J4", expectedColor: "blue", attachToStoppedTurn: true
        )
    }

    @MainActor
    func testLiveGGUFCanStopEarlyAndImmediatelyResendAfterPartialOutput() throws {
        let seed = "In this story, the lighthouse is named Copper Heron. What is it called? Reply with the name only."
        let recall = "What is the lighthouse called? Answer in one short sentence."
        let earlyPrompt = interruptionPrompt(entryCount: 36)
        let partialPrompt = "Write at least 1200 words explaining how to verify the order and counters in a numbered record list."
        let followUp = "Remind me what name we gave the lighthouse in this chat."
        for attempt in 1...Self.maximumEarlyStopAttempts {
            if attempt > 1 { restartIsolatedChat() }
            selectModel(ggufModelName, backend: "llama")
            assertNameOnly(try completeReply(to: seed), expected: "Copper Heron")

            guard try stopBeforeOutput(earlyPrompt) else { continue }
            assertOrdinaryRecall(try completeReply(to: recall), lighthouse: "Copper Heron")

            // Draft the successor while the partial reply is still streaming.
            // Click Stop and Send consecutively before waiting for a reply.
            let priorFollowUpCount = submittedUserTurns(for: followUp).count
            XCTAssertEqual(priorFollowUpCount, 0)
            let priorPartialCount = try sendPrompt(partialPrompt)
            assertPromptSubmitted(partialPrompt, after: priorPartialCount)
            let stop = app.buttons["Stop generation"]
            let visiblePartial = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return stop.exists && self.assistantReply(after: partialPrompt, in: self.transcriptLabels()) != nil
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [visiblePartial], timeout: 20), .completed)
            try draftPrompt(followUp)
            let partial = try XCTUnwrap(assistantReply(after: partialPrompt, in: transcriptLabels()))
            XCTAssertTrue(stop.exists && stop.isHittable, "Stop must be active after visible GGUF output")
            print("REAL_MODEL_STOP mode=partial phase=before visibleCharacters=\(partial.count)")
            stop.click()
            app.buttons["Send message"].click()

            assertPromptSubmitted(followUp, after: priorFollowUpCount)
            let successor = try completedReply(after: followUp)
            let settled = transcriptLabels()
            XCTAssertEqual(assistantReply(after: followUp, in: settled), successor)
            let retained = try XCTUnwrap(assistantReply(after: partialPrompt, in: settled.dropLast(2)))
            XCTAssertTrue(retained.hasPrefix(partial), "Stop should preserve the text already visible")
            print("REAL_MODEL_STOP mode=partial phase=after retainedCharacters=\(retained.count)")
            assertOrdinaryRecall(successor, lighthouse: "Copper Heron")
            return
        }
        XCTFail("The real GGUF turn did not stop before visible output in \(Self.maximumEarlyStopAttempts) attempts")
    }

    @MainActor
    private func verifyImageRecallAfterEarlyStop(
        card: String,
        identifier: String,
        expectedColor: String,
        attachToStoppedTurn: Bool
    ) throws {
        let seed = "Use identifier \(identifier). Reply exactly \(identifier)."
        let recall = "What is the identifier, and what is the dominant color in the attached image? Reply with the identifier and one color."
        for attempt in 1...Self.maximumEarlyStopAttempts {
            if attempt > 1 { restartIsolatedChat() }
            selectModel(mlxModelName, backend: "mlx")
            if !attachToStoppedTurn { try attachImage(named: card) }
            assertNameOnly(try completeReply(to: seed), expected: identifier)
            if attachToStoppedTurn { try attachImage(named: card) }

            guard try stopBeforeOutput(interruptionPrompt()) else { continue }
            let answer = try completeReply(to: recall)
            let answerWords = words(in: answer)
            XCTAssertTrue(answer.localizedCaseInsensitiveContains(identifier), "Expected the established identifier in: \(answer)")
            XCTAssertTrue(answerWords.contains(expectedColor), "Expected the color of the selected image in: \(answer)")
            let otherColor = expectedColor == "red" ? "blue" : "red"
            XCTAssertFalse(answerWords.contains(otherColor), "The response must identify the selected image's color: \(answer)")
            XCTAssertTrue(isBriefImageRecall(answer), "The image reply must be brief and avoid continuing the interrupted request: \(answer)")

            let transcript = XCTAttachment(string: answer)
            transcript.name = "Completed image reply \(card)"
            transcript.lifetime = .keepAlways
            add(transcript)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Completed image recall \(card)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            return
        }
        XCTFail("The real MLX turn did not stop before visible output in \(Self.maximumEarlyStopAttempts) attempts")
    }

    private func isBriefImageRecall(_ answer: String) -> Bool {
        // An accessibility label may expose only the beginning of a long reply.
        // That must not pass just because the model included the identifier and color.
        answer.count <= 128 && Set(words(in: answer)).isDisjoint(with: ["sequence", "counter", "counters"])
    }

    private func interruptionPrompt(entryCount: Int = 24) -> String {
        // The note list makes the model process enough real context for the
        // test to have a chance to click Stop before a first token. It also
        // asks for a long answer so a partial-output stop is observable.
        let notes = (1...entryCount).map { index in
            "Entry \(index) follows entry \(index - 1). Its counter is \(index + 24). Verify that the sequence advances by one position and explain how the next entry is calculated."
        }.joined(separator: " ")
        return "Write an explanation of at least 1200 words about the order and counter values in this sequence log. \(notes)"
    }

    @MainActor
    private func restartIsolatedChat() {
        // The real-model arguments still select the native engines, and the
        // app process gets a fresh in-memory store and no prior generation.
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(assistantBubbles().isEmpty, "A retry must start without any prior answer")
    }

    @MainActor
    private func attachImage(named asset: String) throws {
        let source = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: asset, withExtension: "png"),
            "The Mac UI test bundle must contain \(asset).png"
        )
        let directory = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: imageURL)

        let attach = app.buttons["Attach image"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5) && attach.isHittable)
        let thumbnail = app.buttons["Remove attachment"]
        XCTAssertFalse(thumbnail.exists, "The draft must start without an image")
        attach.click()

        let openPanel = app.sheets.matching(identifier: "open-panel").firstMatch
        let open = openPanel.buttons.matching(identifier: "OKButton").firstMatch
        guard open.waitForExistence(timeout: 5) else {
            try failPicker("The native image picker did not expose its Open button")
        }
        app.typeKey("g", modifierFlags: [.command, .shift])

        let goToFolder = openPanel.sheets.matching(identifier: "GoToWindow").firstMatch
        let pathField = goToFolder.textFields.matching(identifier: "PathTextField").firstMatch
        try requirePickerElement(pathField, description: "The picker did not expose its Go to Folder entry field")
        // XCUIElement.hasFocus is unavailable on macOS. The scoped field's
        // diagnostic identifies keyboard focus before any keys are sent.
        guard pathField.debugDescription.contains("Keyboard Focused") else {
            try failPicker("The Go to Folder path field did not receive keyboard focus")
        }
        pathField.typeKey("a", modifierFlags: .command)
        pathField.typeText(directory.path)
        guard let path = pathField.value as? String,
              path == directory.path || path == directory.path + "/" else {
            try failPicker("The Go to Folder path field did not contain the fixture directory")
        }
        pathField.typeKey(.return, modifierFlags: [])
        guard goToFolder.waitForNonExistence(timeout: 5) else {
            try failPicker("The Go to Folder sheet did not close after accepting the fixture directory")
        }

        let fileList = openPanel.descendants(matching: .any).matching(identifier: "ListView").firstMatch
        let image = fileList.textFields.matching(NSPredicate(
            format: "value == %@", imageURL.lastPathComponent
        )).firstMatch
        try requirePickerElement(image, description: "The native picker did not list \(imageURL.lastPathComponent)")
        image.click()
        try requirePickerElement(open, description: "The Open button did not become available for the selected PNG")
        open.click()
        guard openPanel.waitForNonExistence(timeout: 5) else {
            try failPicker("The native image picker did not close after opening the selected PNG")
        }

        // ChatInputBar renders this control only on the image draft thumbnail.
        guard thumbnail.waitForExistence(timeout: 10), thumbnail.isHittable else {
            try failPicker("The chosen PNG did not appear as a draft image thumbnail")
        }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Native draft attachment \(asset)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private struct PickerControlUnavailable: Error {}

    @MainActor
    private func requirePickerElement(_ element: XCUIElement, description: String) throws {
        if !element.waitForExistence(timeout: 5) || !element.isHittable || !element.isEnabled {
            try failPicker(description)
        }
    }

    @MainActor
    private func failPicker(_ description: String) throws -> Never {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = description
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail(description)
        throw PickerControlUnavailable()
    }

    @MainActor
    private func stopBeforeOutput(_ prompt: String) throws -> Bool {
        let stop = app.buttons["Stop generation"]
        let conversation = app.descendants(matching: .any).matching(identifier: "chat-conversation").firstMatch
        let priorPromptCount = try sendPrompt(prompt)
        let deadline = Date().addingTimeInterval(3)
        var stopExists = stop.exists
        while !stopExists && Date() < deadline {
            stopExists = stop.exists
        }
        guard stopExists else {
            assertPromptSubmitted(prompt, after: priorPromptCount)
            XCTAssertFalse(hasTurnFailure(), "The real turn must not fail or request a tool")
            let regenerate = app.buttons["Regenerate last response"]
            let completedTooSoon = assistantReply(after: prompt, in: transcriptLabels()) != nil
                && regenerate.exists && regenerate.isEnabled
            XCTAssertTrue(completedTooSoon, "Stop never became reachable and completion was not observed")
            if completedTooSoon {
                print("REAL_MODEL_STOP mode=early result=completed-before-stop-was-reachable")
            }
            return false
        }
        // Read the ordered transcript in one accessibility call so per-row
        // lookups do not consume the window before the native Stop click.
        let beforeStop = try transcriptSnapshotLabels(in: conversation)
        let lateBeforeStop = assistantReply(after: prompt, in: beforeStop) != nil
        print("REAL_MODEL_STOP mode=early phase=before visibleNewText=\(lateBeforeStop)")
        stop.click()
        let idle = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 10), .completed, "Stop should settle the real turn")
        XCTAssertFalse(hasTurnFailure(), "Cancellation must not leave an error or tool request")
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 10))
        // Check receipt after clicking Stop so the extra snapshots do not
        // consume the window before the first token is displayed.
        assertPromptSubmitted(prompt, after: priorPromptCount)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Submitted prompt after Stop"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let settled = transcriptLabels()
        let lateAfterStop = assistantReply(after: prompt, in: settled) != nil
        let interruptedPromptIsLast = settled.last == expectedTranscriptLabel(for: prompt)
        print("REAL_MODEL_STOP mode=early phase=after visibleNewText=\(lateAfterStop) interruptedPromptIsLast=\(interruptedPromptIsLast)")
        if lateBeforeStop || lateAfterStop {
            print("REAL_MODEL_STOP mode=early result=visible-output-arrived-before-stop-settled")
            return false
        }
        XCTAssertTrue(interruptedPromptIsLast, "Early Stop must leave its user prompt at the end of the transcript")
        XCTAssertFalse(app.buttons["Regenerate last response"].exists, "An empty assistant entry must not survive early Stop")
        return true
    }

    private struct DraftTextMismatch: Error {}

    @MainActor
    private func draftPrompt(_ prompt: String) throws {
        let input = try XCTUnwrap(findMessageInput(app: app))
        XCTAssertTrue(input.isEnabled && input.isHittable, "The composer must be ready for text entry")
        input.click()
        input.typeText(prompt)
        let composerValue = input.value as? String
        guard composerValue == prompt else {
            capturePromptMismatch(
                "Composer value before Send",
                expected: prompt,
                observed: composerValue.map { [$0] } ?? []
            )
            XCTFail("The composer must contain the full prompt before Send")
            throw DraftTextMismatch()
        }
    }

    @MainActor
    private func sendPrompt(_ prompt: String) throws -> Int {
        let priorPromptCount = submittedUserTurns(for: prompt).count
        try draftPrompt(prompt)
        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5) && send.isEnabled)
        app.typeKey(.return, modifierFlags: .command)
        return priorPromptCount
    }

    private func expectedTranscriptLabel(for prompt: String) -> String {
        let sentText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return String("User said: \(sentText)".prefix(Self.transcriptLabelLimit))
    }

    @MainActor
    private func submittedUserTurns(for prompt: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", expectedTranscriptLabel(for: prompt)
        ))
    }

    @MainActor
    private func assertPromptSubmitted(_ prompt: String, after priorPromptCount: Int) {
        let turns = submittedUserTurns(for: prompt)
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            turns.count > priorPromptCount
        }, object: nil)
        let receiptStatus = XCTWaiter.wait(for: [appeared], timeout: 5)
        let turnCount = turns.count
        let input = app.textFields["Message input"]
        let draft = input.exists ? (input.value as? String ?? "") : ""
        let draftIsEmpty = input.exists && (draft.isEmpty || draft == input.placeholderValue)
        let stopVisible = app.buttons["Stop generation"].exists
        print("REAL_MODEL_SEND turnsBefore=\(priorPromptCount) turnsAfter=\(turnCount) draftIsEmpty=\(draftIsEmpty) stopVisible=\(stopVisible)")
        if receiptStatus != .completed || turnCount != priorPromptCount + 1 || !draftIsEmpty {
            let userRows = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@", "User said:"
            )).allElementsBoundByIndex
            capturePromptMismatch(
                "User transcript after Send",
                expected: expectedTranscriptLabel(for: prompt),
                observed: userRows.map(\.label)
            )
            XCTFail("Send must add exactly one matching user turn and clear its draft")
        }
    }

    @MainActor
    private func capturePromptMismatch(_ name: String, expected: String, observed: [String]) {
        let descriptions = observed.map { value in
            let matchingLength = zip(expected, value).prefix(while: { $0.0 == $0.1 }).count
            return "Observed length: \(value.count), matching prefix length: \(matchingLength)\n\(value)"
        }
        let details = "Expected length: \(expected.count)\n\(expected)\n\n" + descriptions.joined(separator: "\n\n")
        let comparison = XCTAttachment(string: details)
        comparison.name = name
        comparison.lifetime = .keepAlways
        add(comparison)

        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name) accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name) screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func completeReply(to prompt: String) throws -> String {
        let priorPromptCount = try sendPrompt(prompt)
        assertPromptSubmitted(prompt, after: priorPromptCount)
        return try completedReply(after: prompt)
    }

    @MainActor
    private func completedReply(after prompt: String) throws -> String {
        let stop = app.buttons["Stop generation"]
        let regenerate = app.buttons["Regenerate last response"]
        let terminal = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            guard let self else { return false }
            if self.hasTurnFailure() { return true }
            return !stop.exists && regenerate.exists && regenerate.isEnabled
                && self.assistantReply(after: prompt, in: self.transcriptLabels()) != nil
        }, object: nil)
        let finished = XCTWaiter.wait(for: [terminal], timeout: 180) == .completed
        if !finished || hasTurnFailure() || stop.exists {
            capturePromptMismatch(
                "Expected completed reply to submitted prompt",
                expected: expectedTranscriptLabel(for: prompt),
                observed: transcriptLabels()
            )
            XCTFail("The submitted prompt must receive a completed reply without tools or errors")
        }
        return try XCTUnwrap(assistantReply(after: prompt, in: transcriptLabels()))
    }

    private func assistantReply(after prompt: String, in labels: some Collection<String>) -> String? {
        let tail = Array(labels.suffix(2))
        guard tail.count == 2, tail[0] == expectedTranscriptLabel(for: prompt),
              tail[1].hasPrefix("Assistant said:") else { return nil }
        let response = tail[1].dropFirst("Assistant said:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return response.isEmpty ? nil : response
    }

    @MainActor
    private func transcriptLabels() -> [String] {
        let conversation = app.descendants(matching: .any).matching(identifier: "chat-conversation").firstMatch
        return conversation.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH 'User said:' OR label BEGINSWITH 'Assistant said:'"
        )).allElementsBoundByIndex.map(\.label)
    }

    @MainActor
    private func transcriptSnapshotLabels(in conversation: XCUIElement) throws -> [String] {
        let transcript = try conversation.snapshot()
        var labels: [String] = []
        func collect(_ node: any XCUIElementSnapshot) {
            let label = node.label
            if label.hasPrefix("User said:") || label.hasPrefix("Assistant said:") {
                labels.append(label)
            }
            for child in node.children {
                collect(child)
            }
        }
        collect(transcript)
        return labels
    }

    private func words(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private func assertNameOnly(_ answer: String, expected: String) {
        XCTAssertEqual(words(in: answer), words(in: expected), "The seed must establish only the name and leave the image color unstated")
    }

    private func assertOrdinaryRecall(_ answer: String, lighthouse: String) {
        XCTAssertTrue(answer.localizedCaseInsensitiveContains(lighthouse), "Expected the established name in: \(answer)")
        XCTAssertFalse(answer.contains("{") || answer.contains("```"), "The tool-free answer should be ordinary prose: \(answer)")
    }

    @MainActor
    private func loadVerifyAndGenerate(model: String, backend: String, prompt: String) {
        selectModel(model, backend: backend)

        let assistantCountBefore = assistantBubbles().count
        guard let input = findMessageInput(app: app) else {
            XCTFail("Message input should be available after loading \(model)")
            return
        }
        input.click()
        input.typeText(prompt)

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(
            sendButton.waitForExistence(timeout: 5) && sendButton.isEnabled,
            "Send should be enabled after typing a prompt for \(model)"
        )
        sendButton.click()

        XCTAssertTrue(
            waitForCompletedReplyWithoutTools(afterCount: assistantCountBefore, timeout: 180),
            "The real \(backend) turn must add a completed reply without tool calls or errors"
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
    private func selectModel(_ model: String, backend: String) {
        openModelSwitcher()
        let switcher = app.descendants(matching: .any)["model-switcher-list"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "Model switcher should open before selecting \(model)")

        let row = descendant(in: switcher, containing: model)
        XCTAssertTrue(
            row.waitForExistence(timeout: 15) && row.isHittable,
            "The discovered installed model should be selectable: \(model)"
        )
        row.click()

        // The macOS switcher is a popover that stays open after selection.
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 300),
            "Composer should become ready only after the real \(backend) model load completes"
        )
        assertSelectedModelChip(model: model, backend: backend)
    }

    @MainActor
    private var modelSwitcherChips: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "chat-model-switcher-chip")
    }

    @MainActor
    private func openModelSwitcher() {
        reachableModelSwitcherChip()?.element.click()
    }

    @MainActor
    private func reachableModelSwitcherChip() -> (element: XCUIElement, openedOverflow: Bool)? {
        let chips = modelSwitcherChips
        // The label and composer can update before AppKit finishes laying
        // out the new toolbar button and reports its hit target.
        if let chip = firstHittable(in: chips, timeout: 5) {
            return (chip, false)
        }

        // The principal toolbar item can move into macOS's More menu.
        // Open the native menu and look for the same app-owned control.
        let moreButtons = app.toolbars.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'More' OR value CONTAINS[c] 'More'")
        )
        guard let more = firstHittable(in: moreButtons, timeout: 5) else {
            XCTFail("The model switcher must be reachable in the toolbar or its More menu")
            return nil
        }
        more.click()
        guard let chip = firstHittable(in: chips, timeout: 5) else {
            XCTFail("The More menu must expose the identified model switcher")
            return nil
        }
        return (chip, true)
    }

    @MainActor
    private func firstHittable(in query: XCUIElementQuery, timeout: TimeInterval) -> XCUIElement? {
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            query.allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
        }, object: nil)
        guard XCTWaiter.wait(for: [reachable], timeout: timeout) == .completed else { return nil }
        return query.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }

    @MainActor
    private func waitForCompletedReplyWithoutTools(afterCount count: Int, timeout: TimeInterval) -> Bool {
        let stop = app.buttons["Stop generation"]
        let regenerate = app.buttons["Regenerate last response"]
        let terminal = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                if self.hasTurnFailure() { return true }
                let bubbles = self.assistantBubbles()
                guard bubbles.count > count, let newest = bubbles.last else { return false }
                let prefix = "Assistant said:"
                let label = newest.label.trimmingCharacters(in: .whitespacesAndNewlines)
                // A short answer can finish before XCTest observes Stop.
                // Regenerate is rendered only when generation is idle and
                // the last transcript message is an assistant response.
                return label.hasPrefix(prefix) && label.count > prefix.count
                    && !stop.exists && regenerate.exists && regenerate.isEnabled
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [terminal], timeout: timeout) == .completed else { return false }
        return !hasTurnFailure() && !stop.exists
    }

    @MainActor
    private func hasTurnFailure() -> Bool {
        let approval = app.descendants(matching: .any)["approval-sheet-title"]
        let failure = app.descendants(matching: .any)["turn-failure-card"]
        let errorBanner = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH 'Error:'")
        ).firstMatch
        let toolInvocation = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'tool-invocation-'")
        ).firstMatch
        return approval.exists || failure.exists || errorBanner.exists || toolInvocation.exists
    }

    @MainActor
    private func assertSelectedModelChip(model: String, backend: String) {
        guard let reachability = reachableModelSwitcherChip() else { return }
        defer {
            if reachability.openedOverflow {
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // The clickable child and the node with the model label can share
        // the chip identifier. Prove reachability and identity on each.
        let modelChip = modelSwitcherChips.matching(
            NSPredicate(format: "label CONTAINS[c] %@", model)
        ).firstMatch
        XCTAssertTrue(
            modelChip.waitForExistence(timeout: 15),
            "The selected \(backend) model chip should identify \(model)"
        )
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

    private func displayName(for path: String, strippingExtension: Bool = false) -> String {
        let url = URL(fileURLWithPath: path)
        let rawName: String
        if strippingExtension {
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

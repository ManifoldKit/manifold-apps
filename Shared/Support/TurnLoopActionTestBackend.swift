import Foundation
import ManifoldInference
import os

/// Test-only backend for the released ChatView edit, regenerate, and Stop actions.
/// Each answer is conditional on the exact conversation sent to inference, so
/// an action that leaves stale downstream turns cannot receive a passing reply.
final class TurnLoopActionTestBackend: InferenceBackend, Sendable {
    enum Flow {
        case regenerate
        case edit
        case stop(LaunchArguments.TurnLoopStopMode)
    }

    private typealias EventStream = AsyncThrowingStream<GenerationEvent, Error>

    private enum Response: Sendable {
        case complete(String)
        case holdUntilStopped(partial: String?)
    }

    private struct ExpectedTurn: Sendable {
        let prompt: String
        let history: [(role: String, content: String)]
        let response: Response
    }

    private struct HeldResponse: Sendable {
        let turn: Int
        let continuation: EventStream.Continuation
    }

    private struct State: Sendable {
        var isModelLoaded = true
        var nextTurn = 0
        var heldResponse: HeldResponse?
    }

    private static let earlierPrompt = "Keep this earlier prompt"
    private static let earlierAnswer = "Earlier answer stays."
    private static let originalPrompt = "Change this answer"
    private static let originalAnswer = "Original target answer."
    private static let laterPrompt = "Discard this later prompt"
    private static let laterAnswer = "Later answer to discard."
    private static let editedPrompt = "Use this edited prompt"
    private static let replacementAnswer = "Replacement target answer."
    private static let interruptedPrompt = "Stop this reply"
    // The normal runtime flushes at 128 characters. A full batch makes this
    // partial answer visible while the stream is held, without a timer.
    private static let partialAnswer = "This partial answer stays. The lighthouse keeper wrote that the lamp was lit and that the small boat had reached the harbor safely before nightfall."
    private static let followUpPrompt = "Reply in this same chat"
    private static let followUpAnswer = "The same chat still works."

    private static func unexpectedTurn(
        step: Int,
        prompt: String,
        history: [(role: String, content: String)]
    ) -> String {
        let transcript = history.map { "\($0.role):\($0.content)" }.joined(separator: " | ")
        return "Fixture error at step \(step): prompt [\(prompt)], history [\(transcript)]."
    }

    private let expectedTurns: [ExpectedTurn]
    private let state = OSAllocatedUnfairLock(initialState: State())

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        // The host advertises its reference tools even in these tests. The
        // released queue rejects that request before generate() unless this
        // backend accepts tool definitions, just like ScriptedBackend does.
        supportsToolCalling: true,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )

    init(flow: Flow) {
        let first = ExpectedTurn(
            prompt: Self.earlierPrompt,
            history: [("user", Self.earlierPrompt)],
            response: .complete(Self.earlierAnswer)
        )
        let secondHistory = [
            ("user", Self.earlierPrompt),
            ("assistant", Self.earlierAnswer),
            ("user", Self.originalPrompt),
        ]
        let second = ExpectedTurn(
            prompt: Self.originalPrompt,
            history: secondHistory,
            response: .complete(Self.originalAnswer)
        )
        switch flow {
        case .regenerate:
            expectedTurns = [
                first,
                second,
                ExpectedTurn(
                    prompt: Self.originalPrompt,
                    history: secondHistory,
                    response: .complete(Self.replacementAnswer)
                ),
            ]
        case .edit:
            expectedTurns = [
                first,
                second,
                ExpectedTurn(
                    prompt: Self.laterPrompt,
                    history: secondHistory + [
                        ("assistant", Self.originalAnswer),
                        ("user", Self.laterPrompt),
                    ],
                    response: .complete(Self.laterAnswer)
                ),
                ExpectedTurn(
                    prompt: Self.editedPrompt,
                    history: [
                        ("user", Self.earlierPrompt),
                        ("assistant", Self.earlierAnswer),
                        ("user", Self.editedPrompt),
                    ],
                    response: .complete(Self.replacementAnswer)
                ),
            ]
        case .stop(let mode):
            let partialAnswer = mode == .afterPartialOutput ? Self.partialAnswer : nil
            let interruptedHistory = [
                ("user", Self.earlierPrompt),
                ("assistant", Self.earlierAnswer),
                ("user", Self.interruptedPrompt),
            ]
            var followUpHistory = interruptedHistory
            if let partialAnswer {
                followUpHistory.append(("assistant", partialAnswer))
            }
            followUpHistory.append(("user", Self.followUpPrompt))
            expectedTurns = [
                first,
                ExpectedTurn(
                    prompt: Self.interruptedPrompt,
                    history: interruptedHistory,
                    response: .holdUntilStopped(partial: partialAnswer)
                ),
                ExpectedTurn(
                    prompt: Self.followUpPrompt,
                    history: followUpHistory,
                    response: .complete(Self.followUpAnswer)
                ),
            ]
        }
    }

    var isModelLoaded: Bool {
        state.withLock { $0.isModelLoaded }
    }

    var isGenerating: Bool {
        state.withLock { $0.heldResponse != nil }
    }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        state.withLock { $0.isModelLoaded = true }
    }

    func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        let (stream, continuation) = EventStream.makeStream()
        let response = state.withLock { state -> Response in
            let turn = state.nextTurn
            let history = hints.history.map { (role: $0.role, content: $0.textContent) }
            guard state.heldResponse == nil, turn < expectedTurns.count else {
                return .complete(Self.unexpectedTurn(step: turn + 1, prompt: prompt, history: history))
            }
            let expected = expectedTurns[turn]
            guard prompt == expected.prompt,
                  history.count == expected.history.count,
                  zip(history, expected.history).allSatisfy({ actual, wanted in
                      actual.role == wanted.role && actual.content == wanted.content
                  }),
                  hints.history.allSatisfy({ message in
                      message.parts.allSatisfy { part in
                          if case .text = part { return true }
                          return false
                      }
                  }) else {
                return .complete(Self.unexpectedTurn(step: turn + 1, prompt: prompt, history: history))
            }
            state.nextTurn += 1
            if case .holdUntilStopped = expected.response {
                continuation.onTermination = { [weak self] _ in
                    self?.state.withLock { state in
                        if state.heldResponse?.turn == turn {
                            state.heldResponse = nil
                        }
                    }
                }
                state.heldResponse = HeldResponse(turn: turn, continuation: continuation)
            }
            return expected.response
        }
        switch response {
        case .complete(let answer):
            continuation.yield(.token(answer))
            continuation.finish()
        case .holdUntilStopped(let partial):
            if let partial {
                continuation.yield(.token(partial))
            }
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {
        cancelHeldResponse(unloading: false)
    }

    func unloadModel() {
        cancelHeldResponse(unloading: true)
    }

    private func cancelHeldResponse(unloading: Bool) {
        let heldResponse = state.withLock { state in
            if unloading { state.isModelLoaded = false }
            let heldResponse = state.heldResponse
            state.heldResponse = nil
            return heldResponse
        }
        // finish invokes onTermination, which also takes the state lock.
        heldResponse?.continuation.finish(throwing: CancellationError())
    }
}

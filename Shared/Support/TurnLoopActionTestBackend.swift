import Foundation
import ManifoldInference
import os

/// Test-only backend for the released ChatView edit and regenerate actions.
/// Each answer is conditional on the exact conversation sent to inference, so
/// an action that leaves stale downstream turns cannot receive a passing reply.
final class TurnLoopActionTestBackend: InferenceBackend, Sendable {
    enum Flow {
        case regenerate
        case edit
    }

    private struct ExpectedTurn: Sendable {
        let prompt: String
        let history: [(role: String, content: String)]
        let answer: String
    }

    private struct State: Sendable {
        var isModelLoaded = true
        var isGenerating = false
        var nextTurn = 0
    }

    private static let earlierPrompt = "Keep this earlier prompt"
    private static let earlierAnswer = "Earlier answer stays."
    private static let originalPrompt = "Change this answer"
    private static let originalAnswer = "Original target answer."
    private static let laterPrompt = "Discard this later prompt"
    private static let laterAnswer = "Later answer to discard."
    private static let editedPrompt = "Use this edited prompt"
    private static let replacementAnswer = "Replacement target answer."
    private static let unexpectedTurn = "Fixture error: unexpected prompt or conversation history."

    private let expectedTurns: [ExpectedTurn]
    private let state = OSAllocatedUnfairLock(initialState: State())

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: false,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )

    init(flow: Flow) {
        let first = ExpectedTurn(
            prompt: Self.earlierPrompt,
            history: [("user", Self.earlierPrompt)],
            answer: Self.earlierAnswer
        )
        let secondHistory = [
            ("user", Self.earlierPrompt),
            ("assistant", Self.earlierAnswer),
            ("user", Self.originalPrompt),
        ]
        let second = ExpectedTurn(
            prompt: Self.originalPrompt,
            history: secondHistory,
            answer: Self.originalAnswer
        )
        switch flow {
        case .regenerate:
            expectedTurns = [
                first,
                second,
                ExpectedTurn(
                    prompt: Self.originalPrompt,
                    history: secondHistory,
                    answer: Self.replacementAnswer
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
                    answer: Self.laterAnswer
                ),
                ExpectedTurn(
                    prompt: Self.editedPrompt,
                    history: [
                        ("user", Self.earlierPrompt),
                        ("assistant", Self.earlierAnswer),
                        ("user", Self.editedPrompt),
                    ],
                    answer: Self.replacementAnswer
                ),
            ]
        }
    }

    var isModelLoaded: Bool {
        state.withLock { $0.isModelLoaded }
    }

    var isGenerating: Bool {
        state.withLock { $0.isGenerating }
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
        let answer = state.withLock { state -> String in
            let turn = state.nextTurn
            guard turn < expectedTurns.count else { return Self.unexpectedTurn }
            let expected = expectedTurns[turn]
            let history = hints.history.map { (role: $0.role, content: $0.textContent) }
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
                return Self.unexpectedTurn
            }
            state.nextTurn += 1
            return expected.answer
        }
        state.withLock { $0.isGenerating = true }
        let raw = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            Task {
                continuation.yield(.token(answer))
                state.withLock { $0.isGenerating = false }
                continuation.finish()
            }
        }
        return GenerationStream(raw)
    }

    func stopGeneration() {
        state.withLock { $0.isGenerating = false }
    }

    func unloadModel() {
        state.withLock { state in
            state.isGenerating = false
            state.isModelLoaded = false
        }
    }
}

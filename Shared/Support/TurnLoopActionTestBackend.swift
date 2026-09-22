import Foundation
import ManifoldInference
import os

/// Test-only backend for the released ChatView turn-loop actions.
/// Each answer is conditional on the exact conversation sent to inference, so
/// an action that leaves stale downstream turns cannot receive a passing reply.
final class TurnLoopActionTestBackend: InferenceBackend, Sendable {
    enum Flow {
        case regenerate
        case edit
        case cancel
        case branch
    }

    private struct ExpectedTurn: Sendable {
        let prompt: String
        let history: [(role: String, content: String)]
        let answer: String
        let waitsForCancellation: Bool
        let requiresCancellationProof: Bool

        init(
            prompt: String,
            history: [(role: String, content: String)],
            answer: String,
            waitsForCancellation: Bool = false,
            requiresCancellationProof: Bool = false
        ) {
            self.prompt = prompt
            self.history = history
            self.answer = answer
            self.waitsForCancellation = waitsForCancellation
            self.requiresCancellationProof = requiresCancellationProof
        }
    }

    private struct State: Sendable {
        var isModelLoaded = true
        var isGenerating = false
        var nextTurn = 0
        var activeGenerationID: UUID?
        var activeContinuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
        var rejectedLateCancellationToken = false
    }

    private static let earlierPrompt = "Keep this earlier prompt"
    private static let earlierAnswer = "Earlier answer stays."
    private static let originalPrompt = "Change this answer"
    private static let originalAnswer = "Original target answer."
    private static let laterPrompt = "Discard this later prompt"
    private static let laterAnswer = "Later answer to discard."
    private static let editedPrompt = "Use this edited prompt"
    private static let replacementAnswer = "Replacement target answer."
    private static let cancellationPrompt = "Start a cancellable response"
    private static let cancelledPrefix =
        "Cancellation is in progress. This visible partial response is intentionally " +
        "long enough to flush through the real streaming buffer before Stop is pressed."
    private static let cancelledStaleSuffix = " Stale output after Stop."
    private static let recoveryPrompt = "Answer after cancellation"
    private static let recoveryAnswer = "Recovery answer completed."
    private static let branchSourcePrompt = "Create branch source history"
    private static let branchSourceAnswer = "Branch source answer."
    private static let branchOnlyPrompt = "Add this only to the branch"
    private static let branchOnlyAnswer = "Branch-only answer."
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
        case .cancel:
            expectedTurns = [
                ExpectedTurn(
                    prompt: Self.cancellationPrompt,
                    history: [("user", Self.cancellationPrompt)],
                    answer: Self.cancelledPrefix,
                    waitsForCancellation: true
                ),
                ExpectedTurn(
                    prompt: Self.recoveryPrompt,
                    history: [
                        ("user", Self.cancellationPrompt),
                        ("assistant", Self.cancelledPrefix),
                        ("user", Self.recoveryPrompt),
                    ],
                    answer: Self.recoveryAnswer,
                    requiresCancellationProof: true
                ),
            ]
        case .branch:
            expectedTurns = [
                first,
                ExpectedTurn(
                    prompt: Self.branchSourcePrompt,
                    history: [
                        ("user", Self.earlierPrompt),
                        ("assistant", Self.earlierAnswer),
                        ("user", Self.branchSourcePrompt),
                    ],
                    answer: Self.branchSourceAnswer
                ),
                ExpectedTurn(
                    prompt: Self.branchOnlyPrompt,
                    history: [
                        ("user", Self.earlierPrompt),
                        ("assistant", Self.earlierAnswer),
                        ("user", Self.branchSourcePrompt),
                        ("assistant", Self.branchSourceAnswer),
                        ("user", Self.branchOnlyPrompt),
                    ],
                    answer: Self.branchOnlyAnswer
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
        guard state.withLock({ $0.activeGenerationID == nil }) else {
            throw InferenceError.inferenceFailure(
                "Turn-loop fixture rejected overlapping generation before cancellation drained."
            )
        }
        let expected = state.withLock { state -> ExpectedTurn in
            let turn = state.nextTurn
            let history = hints.history.map { (role: $0.role, content: $0.textContent) }
            guard turn < expectedTurns.count else {
                return ExpectedTurn(
                    prompt: prompt,
                    history: history,
                    answer: Self.unexpectedTurn(step: turn + 1, prompt: prompt, history: history)
                )
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
                  }),
                  !expected.requiresCancellationProof || state.rejectedLateCancellationToken else {
                return ExpectedTurn(
                    prompt: prompt,
                    history: history,
                    answer: Self.unexpectedTurn(step: turn + 1, prompt: prompt, history: history)
                )
            }
            state.nextTurn += 1
            return expected
        }

        let generationID = UUID()
        let (raw, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        continuation.onTermination = { [self] _ in
            state.withLock { state in
                guard state.activeGenerationID == generationID else { return }
                state.isGenerating = false
                state.activeGenerationID = nil
                state.activeContinuation = nil
            }
        }
        state.withLock { state in
            state.isGenerating = true
            state.activeGenerationID = generationID
            state.activeContinuation = continuation
        }
        continuation.yield(.token(expected.answer))
        if !expected.waitsForCancellation {
            continuation.finish()
        }
        return GenerationStream(raw)
    }

    func stopGeneration() {
        let continuation = state.withLock { state -> AsyncThrowingStream<GenerationEvent, Error>.Continuation? in
            state.isGenerating = false
            return state.activeContinuation
        }
        guard let continuation else { return }
        continuation.finish()
        // Exercise one producer attempt after the terminal signal. Recovery
        // is accepted only when AsyncThrowingStream rejects this token, so a
        // passing next turn proves the cancelled producer cannot overlap it.
        let rejectedLateToken: Bool
        if case .terminated = continuation.yield(.token(Self.cancelledStaleSuffix)) {
            rejectedLateToken = true
        } else {
            rejectedLateToken = false
        }
        state.withLock { $0.rejectedLateCancellationToken = rejectedLateToken }
    }

    func unloadModel() {
        let continuation = state.withLock { state -> AsyncThrowingStream<GenerationEvent, Error>.Continuation? in
            state.isGenerating = false
            state.isModelLoaded = false
            state.activeGenerationID = nil
            let continuation = state.activeContinuation
            state.activeContinuation = nil
            return continuation
        }
        continuation?.finish()
    }
}

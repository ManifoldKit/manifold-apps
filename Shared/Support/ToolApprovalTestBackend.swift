import Foundation
import ManifoldInference
import os

/// Deterministic UI-test backend whose success response is conditional on the
/// real tool-dispatch continuation history and filesystem side effect.
///
/// Unlike `ScriptedBackend`, this backend does not advance to an unconditional
/// second token turn. It emits `write_file` first, then reports success only if
/// the next `GenerationRuntimeHints.history` contains the matching successful
/// `ToolResult` *and* the executor wrote the exact requested bytes to disk.
final class ToolApprovalTestBackend: InferenceBackend, Sendable {
    static let requestedPath = "approval/result.txt"
    static let requestedContents = "approved through the live UI gate"
    static let successMessage = "Tool result history and exact file bytes verified."

    private struct State: Sendable {
        var isModelLoaded = true
        var isGenerating = false
    }

    private struct WriteReceipt: Decodable {
        let path: String
        let bytesWritten: Int
    }

    private let root: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    let capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: true,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )

    init(root: URL) {
        self.root = root
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
        let events = events(config: config, history: hints.history)
        state.withLock { $0.isGenerating = true }

        let raw = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                }
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

    private func events(
        config: GenerationConfig,
        history: [StructuredMessage]
    ) -> [GenerationEvent] {
        let writeCalls = history.flatMap(\.parts).compactMap { part -> ToolCall? in
            guard case .toolCall(let call) = part, call.toolName == "write_file" else {
                return nil
            }
            return call
        }

        guard let call = writeCalls.last else {
            guard config.tools.contains(where: { $0.name == "write_file" }) else {
                return Self.tokens("Tool validation failed: write_file was not advertised.")
            }
            let arguments = #"{"path":"\#(Self.requestedPath)","content":"\#(Self.requestedContents)"}"#
            return [.toolCall(ToolCall(id: "approval-write-0", toolName: "write_file", arguments: arguments))]
        }

        guard validatesResultAndFile(for: call, history: history) else {
            return Self.tokens("Tool validation failed: result history or file bytes were missing.")
        }
        return Self.tokens(Self.successMessage)
    }

    private func validatesResultAndFile(
        for call: ToolCall,
        history: [StructuredMessage]
    ) -> Bool {
        guard let result = history.flatMap(\.parts).compactMap({ part -> ToolResult? in
            guard case .toolResult(let result) = part, result.callId == call.id else {
                return nil
            }
            return result
        }).last,
        result.errorKind == nil else {
            return false
        }

        let receipt: WriteReceipt
        do {
            receipt = try JSONDecoder().decode(WriteReceipt.self, from: Data(result.content.utf8))
        } catch {
            Log.inference.error("Tool approval UI test could not decode the write receipt: \(String(describing: error), privacy: .public)")
            return false
        }
        guard receipt.path == Self.requestedPath,
              receipt.bytesWritten == Self.requestedContents.utf8.count else {
            return false
        }

        do {
            let written = try Data(contentsOf: root.appendingPathComponent(Self.requestedPath))
            return written == Data(Self.requestedContents.utf8)
        } catch {
            Log.inference.error("Tool approval UI test could not read the requested output file: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private static func tokens(_ message: String) -> [GenerationEvent] {
        message.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, token in
            .token(index == 0 ? String(token) : " \(token)")
        }
    }
}

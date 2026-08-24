import ManifoldInference
import ManifoldTools
import XCTest
@testable import Manifold

/// Runs the app's production composition root against installed MLX and GGUF
/// assets without depending on macOS Accessibility automation. The ordinary
/// Mac UI suite retains switcher and chat coverage; this target owns the long
/// local-inference qualification matrix so a locked desktop cannot invalidate
/// backend signal before either model loads.
@MainActor
final class MacRealQualificationIntegrationTests: XCTestCase {
    private var cellTimeoutSeconds: Double {
        guard let rawValue = ProcessInfo.processInfo.environment[
            "MANIFOLD_MAC_REAL_QUALIFICATION_TIMEOUT_SECONDS"
        ], let value = Double(rawValue), value > 0 else {
            return 300
        }
        return value
    }

    func testQualificationCorpusAcrossMLXAndGGUF() async throws {
        guard ProcessInfo.processInfo.environment["MANIFOLD_MAC_REAL_QUALIFICATION_TEST"] == "1" else {
            throw XCTSkip("Run make mac-real-qualification with the required local models.")
        }

        let env = try await AppEnvironment.bootstrap(
            storeName: "MacRealQualification",
            appName: "Manifold Qualification",
            bundleIdentifier: "com.manifoldkit.ManifoldMacQualification"
        )
        ToolsFeature.install(into: env)

        let scenarios = try LocalQualificationCorpus.load()
        XCTAssertEqual(
            scenarios.map(\.id),
            LocalQualificationCorpus.IDs,
            "The published ManifoldTools corpus must contain every app qualification scenario"
        )

        var failures: [String] = []
        for model in env.viewModel.modelRegistry.availableModels {
            env.viewModel.selectedModel = model
            await env.viewModel.loadSelectedModel()
            guard env.viewModel.isModelLoaded else {
                failures.append("\(model.modelType.rawValue)/\(model.name): model failed to load")
                continue
            }
            ToolsFeature.updateAdvertisement(in: env)

            for repeatIndex in 1...2 {
                for scenario in scenarios {
                    do {
                        let outcome = try await run(
                            scenario,
                            service: env.bootstrap.inferenceService
                        )
                        if !outcome.passed {
                            let failedAssertions = outcome.assertions
                                .filter { !$0.passed }
                                .map(\.message)
                                .joined(separator: "; ")
                            let toolResults = outcome.toolResults.map {
                                "\($0.toolName)=\(Self.diagnosticText($0.content))"
                            }
                            failures.append(
                                "\(model.modelType.rawValue)/\(model.name)/\(scenario.id)/repeat-\(repeatIndex): \(failedAssertions); tools=\(outcome.toolCallsExecuted); results=\(toolResults); final=\(Self.diagnosticText(outcome.finalAnswer))"
                            )
                        }
                    } catch {
                        failures.append(
                            "\(model.modelType.rawValue)/\(model.name)/\(scenario.id)/repeat-\(repeatIndex): \(error.localizedDescription)"
                        )
                    }
                }
            }
        }

        // Companion backends own GPU resources whose teardown must finish
        // before XCTest exits. Leaving the final GGUF loaded made llama.cpp's
        // process-global Metal destructor assert after the verdict printed.
        env.viewModel.unloadModel()
        try await Task.sleep(for: .seconds(1))

        XCTAssertTrue(
            failures.isEmpty,
            "Every app-level local-inference qualification cell should pass:\n\(failures.joined(separator: "\n"))"
        )
    }

    private static func diagnosticText(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(flattened.prefix(400))
    }

    private func run(
        _ scenario: Scenario,
        service: InferenceService
    ) async throws -> ScenarioRunner.Outcome {
        var timedOut = false
        let timeout = cellTimeoutSeconds
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return
            }
            timedOut = true
            service.stopGeneration()
        }
        defer { timeoutTask.cancel() }

        let result: Result<ScenarioRunner.Outcome, Error>
        do {
            result = .success(try await ScenarioRunner(service: service).run(scenario))
        } catch {
            result = .failure(error)
        }

        if timedOut {
            guard await waitForGenerationToSettle(service: service) else {
                throw QualificationError.cancellationDidNotSettle(seconds: timeout)
            }
            throw QualificationError.cellTimedOut(seconds: timeout)
        }
        return try result.get()
    }

    private func waitForGenerationToSettle(service: InferenceService) async -> Bool {
        for _ in 0..<100 {
            if !service.isGenerating { return true }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return !service.isGenerating
    }
}

private enum QualificationError: LocalizedError {
    case cellTimedOut(seconds: Double)
    case cancellationDidNotSettle(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .cellTimedOut(let seconds):
            "Qualification cell exceeded \(seconds.formatted()) seconds and generation was cancelled."
        case .cancellationDidNotSettle(let seconds):
            "Qualification cell exceeded \(seconds.formatted()) seconds, but generation did not settle within 10 seconds of cancellation."
        }
    }
}

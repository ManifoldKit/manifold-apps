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
                for scenarioID in LocalQualificationCorpus.IDs {
                    do {
                        let outcome = try await LocalQualificationExecutor.run(
                            scenarioID: scenarioID,
                            using: env,
                            timeoutSeconds: cellTimeoutSeconds
                        )
                        if !outcome.passed {
                            let failedAssertions = outcome.failedAssertions.joined(separator: "; ")
                            let toolResults = outcome.toolResults.map(Self.diagnosticText)
                            failures.append(
                                "\(model.modelType.rawValue)/\(model.name)/\(scenarioID)/repeat-\(repeatIndex): \(failedAssertions); tools=\(outcome.toolCalls); results=\(toolResults); final=\(Self.diagnosticText(outcome.finalAnswer))"
                            )
                        }
                    } catch {
                        failures.append(
                            "\(model.modelType.rawValue)/\(model.name)/\(scenarioID)/repeat-\(repeatIndex): \(error.localizedDescription)"
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

}

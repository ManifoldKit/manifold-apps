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
                        let outcome = try await ScenarioRunner(
                            service: env.bootstrap.inferenceService
                        ).run(scenario)
                        if !outcome.passed {
                            let failedAssertions = outcome.assertions
                                .filter { !$0.passed }
                                .map(\.message)
                                .joined(separator: "; ")
                            failures.append(
                                "\(model.modelType.rawValue)/\(model.name)/\(scenario.id)/repeat-\(repeatIndex): \(failedAssertions)"
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

        XCTAssertTrue(
            failures.isEmpty,
            "Every app-level local-inference qualification cell should pass:\n\(failures.joined(separator: "\n"))"
        )
    }
}

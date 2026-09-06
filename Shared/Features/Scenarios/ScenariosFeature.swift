import Foundation
import ManifoldInference
import ManifoldTools
import Observation
import SwiftUI

/// Runs a curated qualification corpus through the app's active production
/// inference service. The companion backend, prompt renderer, tool registry,
/// dispatch loop, and result continuation are therefore the same path chat
/// uses; this feature does not maintain a second inference implementation.
enum ScenariosFeature: AppFeature {
    static let id = "scenarios"
    static let title = "Scenarios"
    static let systemImage = "play.rectangle.on.rectangle"

    static func install(into env: AppEnvironment) {}

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(ScenarioQualificationView(env: env))
    }
}

/// The app-owned selection from ManifoldTools' shared corpus. Kept outside
/// the view model so the non-UI physical-model gate exercises the identical
/// scenario set without duplicating IDs in a second harness.
enum LocalQualificationCorpus {
    static let IDs = [
        "shopping-list-budget",
        "parallel-readme-comparison",
    ]

    static func load() throws -> [Scenario] {
        let loaded = try ScenarioLoader.loadBuiltIn()
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        return IDs.compactMap { byID[$0] }
    }

    static func scenario(id: String) throws -> Scenario {
        guard let scenario = try load().first(where: { $0.id == id }) else {
            throw LocalQualificationError.missingScenario(id: id)
        }
        return scenario
    }
}

struct LocalQualificationOutcome {
    let passed: Bool
    let failedAssertions: [String]
    let toolCalls: [String]
    let toolResults: [String]
    let finalAnswer: String
}

/// Runs one bounded corpus cell through the same app-owned service the UI
/// uses. Keeping this wrapper in the host module prevents integration tests
/// from linking a second copy of ManifoldTools beside the app's copy.
@MainActor
enum LocalQualificationExecutor {
    static func run(
        scenarioID: String,
        using env: AppEnvironment,
        timeoutSeconds: Double
    ) async throws -> LocalQualificationOutcome {
        let scenario = try LocalQualificationCorpus.scenario(id: scenarioID)
        let service = env.bootstrap.inferenceService
        var timedOut = false
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
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
                throw LocalQualificationError.cancellationDidNotSettle(seconds: timeoutSeconds)
            }
            throw LocalQualificationError.cellTimedOut(seconds: timeoutSeconds)
        }

        let outcome = try result.get()
        return LocalQualificationOutcome(
            passed: outcome.passed,
            failedAssertions: outcome.assertions.filter { !$0.passed }.map(\.message),
            toolCalls: outcome.toolCallsExecuted,
            toolResults: outcome.toolResults.map { "\($0.toolName)=\($0.content)" },
            finalAnswer: outcome.finalAnswer
        )
    }

    private static func waitForGenerationToSettle(service: InferenceService) async -> Bool {
        var consecutiveIdleSamples = 0
        for _ in 0..<100 {
            if service.isGenerating {
                consecutiveIdleSamples = 0
            } else {
                consecutiveIdleSamples += 1
                if consecutiveIdleSamples == 10 { return true }
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return consecutiveIdleSamples == 10
    }
}

private enum LocalQualificationError: LocalizedError {
    case missingScenario(id: String)
    case cellTimedOut(seconds: Double)
    case cancellationDidNotSettle(seconds: Double)

    var errorDescription: String? {
        switch self {
        case .missingScenario(let id):
            "The published qualification corpus is missing scenario '\(id)'."
        case .cellTimedOut(let seconds):
            "Qualification cell exceeded \(seconds.formatted()) seconds and generation was cancelled."
        case .cancellationDidNotSettle(let seconds):
            "Qualification cell exceeded \(seconds.formatted()) seconds, but generation did not settle within 10 seconds of cancellation."
        }
    }
}

@MainActor
@Observable
private final class ScenarioQualificationModel {
    enum Phase: Equatable {
        case idle
        case running
        case passed
        case failed
        case cancelled
    }

    /// A bounded cross-section of the shared ManifoldTools corpus: a mixed
    /// two-tool chain and repeated same-tool dispatch. Every curated scenario
    /// declares its required tools, keeping the advertised schema count inside
    /// the documented local-model ceiling rather than passing the full app
    /// registry for tool-free scenarios. The source scenarios remain package
    /// resources, so the app cannot drift a private copy of their assertions.
    let scenarios: [Scenario]
    var selectedScenarioID: String?
    var phase: Phase = .idle
    var outcome: ScenarioRunner.Outcome?
    var errorMessage: String?
    var elapsedSeconds: TimeInterval?

    @ObservationIgnored private var activeRunID: UUID?

    init(requestedScenarioID: String?) {
        do {
            self.scenarios = try LocalQualificationCorpus.load()
            if let requestedScenarioID, self.scenarios.contains(where: { $0.id == requestedScenarioID }) {
                self.selectedScenarioID = requestedScenarioID
            } else {
                self.selectedScenarioID = self.scenarios.first?.id
            }
            if self.scenarios.count != LocalQualificationCorpus.IDs.count {
                let present = Set(self.scenarios.map(\.id))
                let missing = LocalQualificationCorpus.IDs.filter { !present.contains($0) }
                self.errorMessage = "Qualification corpus is incomplete: missing \(missing.joined(separator: ", "))."
            }
        } catch {
            self.scenarios = []
            self.selectedScenarioID = nil
            self.errorMessage = "Could not load the qualification corpus: \(error.localizedDescription)"
        }
    }

    var selectedScenario: Scenario? {
        guard let selectedScenarioID else { return nil }
        return scenarios.first { $0.id == selectedScenarioID }
    }

    var resultLabel: String {
        switch phase {
        case .idle: "Not run"
        case .running: "Running"
        case .passed: "Passed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    func select(_ scenario: Scenario) {
        guard phase != .running else { return }
        selectedScenarioID = scenario.id
        phase = .idle
        outcome = nil
        errorMessage = nil
        elapsedSeconds = nil
    }

    func run(using service: InferenceService) {
        guard phase != .running, let scenario = selectedScenario else { return }

        let runID = UUID()
        activeRunID = runID
        phase = .running
        outcome = nil
        errorMessage = nil
        elapsedSeconds = nil
        let startedAt = ContinuousClock.now

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await ScenarioRunner(service: service).run(scenario)
                guard self.activeRunID == runID else { return }
                self.elapsedSeconds = Self.seconds(since: startedAt)
                self.outcome = result
                self.phase = result.passed ? .passed : .failed
                self.activeRunID = nil
            } catch {
                guard self.activeRunID == runID else { return }
                self.elapsedSeconds = Self.seconds(since: startedAt)
                self.errorMessage = error.localizedDescription
                self.phase = .failed
                self.activeRunID = nil
            }
        }
    }

    func cancel(using service: InferenceService) {
        guard phase == .running else { return }
        activeRunID = nil
        service.stopGeneration()
        phase = .cancelled
        errorMessage = "The qualification run was cancelled."
    }

    private static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let duration = start.duration(to: .now)
        return TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private struct ScenarioQualificationView: View {
    let env: AppEnvironment
    @State private var model: ScenarioQualificationModel

    init(env: AppEnvironment) {
        self.env = env
        _model = State(initialValue: ScenarioQualificationModel(requestedScenarioID: LaunchArguments.scenario))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Active inference path") {
                    LabeledContent("Model", value: activeModelLabel)
                    LabeledContent("Backend", value: env.viewModel.activeBackendName ?? "Not loaded")
                }

                Section("Qualification corpus") {
                    ForEach(model.scenarios, id: \.id) { scenario in
                        Button {
                            model.select(scenario)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(scenarioTitle(scenario))
                                    Spacer()
                                    if model.selectedScenarioID == scenario.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                Text(scenario.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("qualification-scenario-\(scenario.id)")
                    }
                }

                Section("Run") {
                    HStack {
                        Button("Run selected") {
                            model.run(using: env.bootstrap.inferenceService)
                        }
                        .disabled(model.selectedScenario == nil || model.phase == .running)
                        .accessibilityIdentifier("qualification-run-button")

                        if model.phase == .running {
                            Button("Cancel", role: .destructive) {
                                model.cancel(using: env.bootstrap.inferenceService)
                            }
                            .accessibilityIdentifier("qualification-cancel-button")
                        }
                    }

                    LabeledContent("Result", value: model.resultLabel)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("qualification-result")

                    if let elapsedSeconds = model.elapsedSeconds {
                        LabeledContent("Elapsed", value: elapsedSeconds.formatted(.number.precision(.fractionLength(2))) + " s")
                    }
                }

                if let outcome = model.outcome {
                    Section("Observed tool calls") {
                        if outcome.toolCallsExecuted.isEmpty {
                            Text("None")
                        } else {
                            ForEach(Array(outcome.toolCallsExecuted.enumerated()), id: \.offset) { _, name in
                                Text(name)
                            }
                        }
                    }

                    Section("Assertions") {
                        ForEach(Array(outcome.assertions.enumerated()), id: \.offset) { index, assertion in
                            Label(
                                assertion.message,
                                systemImage: assertion.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(assertion.passed ? Color.green : Color.red)
                            .accessibilityIdentifier("qualification-assertion-\(index)")
                        }
                    }

                    Section("Final answer") {
                        Text(outcome.finalAnswer.isEmpty ? "No final text" : outcome.finalAnswer)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("qualification-final-answer")
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section("Reported problem") {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("qualification-error")
                    }
                }
            }
            .navigationTitle("Local Inference Qualification")
            .accessibilityIdentifier("qualification-view")
        }
        .onDisappear {
            if model.phase == .running {
                model.cancel(using: env.bootstrap.inferenceService)
            }
        }
    }

    private var activeModelLabel: String {
        env.viewModel.selectedModel?.name
            ?? env.viewModel.selectedEndpoint?.name
            ?? "No model selected"
    }

    private func scenarioTitle(_ scenario: Scenario) -> String {
        scenario.id
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

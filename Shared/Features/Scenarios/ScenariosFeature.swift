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

    /// A bounded cross-section of the shared ManifoldTools corpus: tool-free
    /// structured output, abstention, a mixed two-tool chain, and repeated
    /// same-tool dispatch. The source scenarios remain package resources, so
    /// the app cannot drift a private copy of their prompts or assertions.
    private static let curatedIDs = [
        "structured-json-extraction",
        "abstention-definition",
        "shopping-list-budget",
        "parallel-readme-comparison",
    ]

    let scenarios: [Scenario]
    var selectedScenarioID: String?
    var phase: Phase = .idle
    var outcome: ScenarioRunner.Outcome?
    var errorMessage: String?
    var elapsedSeconds: TimeInterval?

    @ObservationIgnored private var activeRunID: UUID?

    init(requestedScenarioID: String?) {
        do {
            let loaded = try ScenarioLoader.loadBuiltIn()
            let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            self.scenarios = Self.curatedIDs.compactMap { byID[$0] }
            if let requestedScenarioID, self.scenarios.contains(where: { $0.id == requestedScenarioID }) {
                self.selectedScenarioID = requestedScenarioID
            } else {
                self.selectedScenarioID = self.scenarios.first?.id
            }
            if self.scenarios.count != Self.curatedIDs.count {
                let present = Set(self.scenarios.map(\.id))
                let missing = Self.curatedIDs.filter { !present.contains($0) }
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
                        ForEach(Array(outcome.assertions.enumerated()), id: \.offset) { _, assertion in
                            Label(
                                assertion.message,
                                systemImage: assertion.passed ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(assertion.passed ? Color.green : Color.red)
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

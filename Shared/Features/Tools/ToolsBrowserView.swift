import SwiftUI
import ManifoldInference
import ManifoldUI

/// Sidebar-reachable browser for the executors installed on the same
/// ``ToolRegistry`` the conversation runtime dispatches through.
struct ToolsBrowserView: View {
    let env: AppEnvironment

    @State private var isPolicyPresented = false

    var body: some View {
        // Establish Observation tracking for model/backend switches; the
        // registry itself is MainActor-isolated rather than @Observable.
        let _ = env.viewModel.activeBackendName
        let advertised = env.toolRegistry.advertisedDefinitions
        let registered = env.toolRegistry.definitions
        let hidden = registered.filter { definition in
            !advertised.contains(where: { $0.name == definition.name })
        }

        List {
            Section("Approval") {
                Button {
                    isPolicyPresented = true
                } label: {
                    HStack {
                        Label("Tool approval", systemImage: "checkmark.shield")
                        Spacer()
                        Text(policyLabel)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("tools-policy-button")
            }

            Section {
                Text("\(advertised.count) of \(registered.count) tools advertised")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("tool-advertisement-summary")

                ForEach(advertised, id: \.name) { definition in
                    toolRow(definition, identifierPrefix: "tool-row")
                }
            } header: {
                Text("Advertised tools")
            } footer: {
                Text("Local and unknown backends receive a curated maximum of five definitions. Known cloud backends receive the full reference catalog.")
            }

            if !hidden.isEmpty {
                Section {
                    ForEach(hidden, id: \.name) { definition in
                        toolRow(definition, identifierPrefix: "tool-registered-row")
                    }
                } header: {
                    Text("Registered for cloud and scenarios")
                } footer: {
                    Text("These executors remain installed for deliberate cloud and scenario use, but their schemas are not offered to the active local model.")
                }
            }
        }
        .navigationTitle("Tools")
        .accessibilityIdentifier("tools-browser")
        .sheet(isPresented: $isPolicyPresented) {
            ToolPolicyView()
                .environment(env.viewModel)
        }
    }

    private func toolRow(_ definition: ToolDefinition, identifierPrefix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(definition.name)
                .font(.body.monospaced())
            Text(definition.description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(identifierPrefix)-\(definition.name)")
    }

    private var policyLabel: String {
        switch env.viewModel.toolApprovalPolicy {
        case .alwaysAsk: "Always ask"
        case .askOncePerSession: "Once per session"
        case .askOncePerTool: "Once per tool"
        case .autoApprove: "Auto-approve"
        }
    }
}

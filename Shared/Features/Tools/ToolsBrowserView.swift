import SwiftUI
import ManifoldInference
import ManifoldUI

/// Sidebar-reachable browser for the executors installed on the same
/// ``ToolRegistry`` the conversation runtime dispatches through.
struct ToolsBrowserView: View {
    let env: AppEnvironment

    @State private var isPolicyPresented = false

    var body: some View {
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
                ForEach(env.toolRegistry.definitions, id: \.name) { definition in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(definition.name)
                            .font(.body.monospaced())
                        Text(definition.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("tool-row-\(definition.name)")
                }
            } header: {
                Text("Registered tools")
            } footer: {
                Text("These are the live definitions advertised to the active backend and dispatched by this app's ToolRegistry.")
            }
        }
        .navigationTitle("Tools")
        .accessibilityIdentifier("tools-browser")
        .sheet(isPresented: $isPolicyPresented) {
            ToolPolicyView()
                .environment(env.viewModel)
        }
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

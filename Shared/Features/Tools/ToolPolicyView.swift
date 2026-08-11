import SwiftUI
import ManifoldUI

/// Picker for `UIToolApprovalGate.Policy`.
///
/// The four cases cover the common positions a host app takes on tool
/// approval:
/// - Always ask (most conservative — every call prompts)
/// - Ask once per session (default — prompt once, trust subsequent calls)
/// - Ask once per tool
/// - Auto-approve (no sheet ever — useful for scripted flows and trusted
///   environments)
///
/// Ported from ManifoldKit's `Example/Advanced/Settings/ToolPolicyView.swift`
/// — unchanged.
struct ToolPolicyView: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Tool approval", selection: binding) {
                        Text("Always ask").tag(UIToolApprovalGate.Policy.alwaysAsk)
                        Text("Ask once per session").tag(UIToolApprovalGate.Policy.askOncePerSession)
                        Text("Ask once per tool").tag(UIToolApprovalGate.Policy.askOncePerTool)
                        Text("Auto-approve").tag(UIToolApprovalGate.Policy.autoApprove)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text("Controls whether the model's tool calls pause for your approval. Changes apply to the next tool call.")
                }
            }
            .navigationTitle("Tool Approval")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("tool-policy-done-button")
                }
            }
        }
        .accessibilityIdentifier("tool-policy-sheet")
    }

    private var binding: Binding<UIToolApprovalGate.Policy> {
        Binding(
            get: { viewModel.toolApprovalPolicy },
            set: { viewModel.toolApprovalPolicy = $0 }
        )
    }
}

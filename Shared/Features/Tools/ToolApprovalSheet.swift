import SwiftUI
import ManifoldInference
import ManifoldUI

/// Modal sheet that drives `ChatViewModel.toolApprovalGate` one pending call
/// at a time.
///
/// Presents the Approve/Deny surface whenever the queue has a front-of-line
/// entry. Renders the call summary by hand rather than embedding
/// `ToolInvocationView` in its `.pendingApproval` state, because that state
/// introduces its own "Approve"/"Deny" buttons — XCUITest selectors would
/// then match two hit-targets with the same label.
///
/// Ported from ManifoldKit's `Example/Advanced/ToolApprovalSheet.swift` —
/// unchanged.
struct ToolApprovalSheet: View {

    @Environment(ChatViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    let call: ToolCall

    @State private var denyReason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Approve tool call?")
                .font(.headline)
                .accessibilityIdentifier("approval-sheet-title")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.secondary)
                    Text(call.toolName)
                        .font(.caption.monospaced())
                        .fontWeight(.semibold)
                }
                Text(call.arguments)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            TextField("Reason for denial (optional)", text: $denyReason)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("approval-deny-reason-field")

            HStack {
                Button("Deny") {
                    viewModel.toolApprovalGate?.resolve(
                        callId: call.id,
                        with: .denied(reason: denyReason.isEmpty ? nil : denyReason)
                    )
                    dismiss()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("approval-sheet-deny-button")

                Spacer()

                Button("Approve") {
                    viewModel.toolApprovalGate?.resolve(callId: call.id, with: .approved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("approval-sheet-approve-button")
            }
        }
        .padding(20)
        .frame(minWidth: 340)
    }
}

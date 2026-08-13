import Foundation
import SwiftUI
import ManifoldInference
import ManifoldAppIntents

/// Screen that registers a real AppIntent (``SetReminderIntent``) on the
/// chat tool registry via `AppIntentToolExecutor`.
///
/// Ported from ManifoldKit's own `Example/Advanced/AppIntentToolsView.swift`.
/// The tool appears in the model's tool list as `set_reminder_intent` once
/// the user taps "Register". Subsequent chat turns can invoke it like any
/// other registered tool.
///
/// `toolRegistry` must be the SAME instance the host's `InferenceService`
/// was constructed with (`InferenceService(toolRegistry:)`) for
/// registration here to actually affect chat turns — see
/// `AppIntentsFeature.makeView(env:)` for how the registry reaches this
/// view. The registration status below is read back from that registry after
/// mutation so the screen and its UI test prove the live chat seam changed.
@available(iOS 26, macOS 26, *)
struct AppIntentToolsView: View {

    @Environment(\.dismiss) private var dismiss

    let toolRegistry: ToolRegistry
    let inferenceService: InferenceService
    let inboundHandoffStatus: String

    @State private var registered: Bool = false
    @State private var registeredToolName: String = ""
    @State private var lastSchema: String = ""
    @State private var backgroundHandlerConfigured = false

    var body: some View {
        NavigationStack {
            List {
                Section("AppIntent → Tool") {
                    Text("ManifoldAppIntents bridges any `AppIntent` into the chat tool registry. Tapping `Register` exposes `SetReminderIntent` to the model under the name `set_reminder_intent`.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(registered ? "Registered" : "Register SetReminderIntent") {
                        register()
                    }
                    .disabled(registered)
                    .accessibilityIdentifier("appintent-tools-register-button")

                    if !registeredToolName.isEmpty {
                        Text("Registered in live chat registry: \(registeredToolName)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("appintent-tools-registration-status")
                    }
                }

                Section("Runtime wiring") {
                    Label(
                        inferenceService.toolRegistry === toolRegistry
                            ? "Chat registry connected"
                            : "Chat registry disconnected",
                        systemImage: inferenceService.toolRegistry === toolRegistry
                            ? "checkmark.circle.fill"
                            : "xmark.octagon.fill"
                    )
                    .accessibilityIdentifier("appintent-chat-registry-status")

                    Label(
                        backgroundHandlerConfigured
                            ? "Background intent handler configured"
                            : "Background intent handler unavailable",
                        systemImage: backgroundHandlerConfigured
                            ? "checkmark.circle.fill"
                            : "xmark.octagon.fill"
                    )
                    .accessibilityIdentifier("appintent-background-handler-status")

                    #if os(iOS)
                    Label(
                        appGroupContainerIsAvailable
                            ? "App Group available"
                            : "App Group unavailable",
                        systemImage: appGroupContainerIsAvailable
                            ? "checkmark.circle.fill"
                            : "xmark.octagon.fill"
                    )
                    .accessibilityIdentifier("appintent-app-group-status")
                    #endif

                    Text(inboundHandoffStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("appintent-inbound-handoff-status")
                }

                if !lastSchema.isEmpty {
                    Section("Synthesised JSON Schema") {
                        Text(lastSchema)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("appintent-tools-schema")
                    }
                }
            }
            .navigationTitle("AppIntent Tools")
            .accessibilityIdentifier("appintent-tools-sheet")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                lastSchema = AppIntentToolsView.schemaPreview()
                refreshRegistrationStatus()
            }
            .task {
                backgroundHandlerConfigured = await ManifoldIntentConfiguration.shared.handler != nil
            }
        }
    }

    private func register() {
        guard inferenceService.toolRegistry === toolRegistry else {
            registered = false
            registeredToolName = ""
            Log.ui.error("AppIntentToolsView: refusing to register on a registry not owned by InferenceService")
            return
        }
        let executor = AppIntentToolExecutor(SetReminderIntent.self)
        toolRegistry.register(executor)
        refreshRegistrationStatus(expectedName: executor.definition.name)
        lastSchema = AppIntentToolsView.schemaPreview()
    }

    private func refreshRegistrationStatus(expectedName: String = "set_reminder_intent") {
        let runtimeRegistry = inferenceService.toolRegistry
        registered = runtimeRegistry === toolRegistry
            && runtimeRegistry?.contains(name: expectedName) == true
        registeredToolName = runtimeRegistry?.definitions
            .first(where: { $0.name == expectedName })?
            .name ?? ""
    }

    #if os(iOS)
    private var appGroupContainerIsAvailable: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ManifoldAppGroup.identifier
        ) != nil
    }
    #endif

    private static func schemaPreview() -> String {
        let executor = AppIntentToolExecutor(SetReminderIntent.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(executor.definition.parameters)
            return String(data: data, encoding: .utf8) ?? "<schema is not UTF-8>"
        } catch {
            Log.ui.error("AppIntentToolsView: failed to render schema preview: \(String(describing: error), privacy: .public)")
            return "<unable to render schema>"
        }
    }
}

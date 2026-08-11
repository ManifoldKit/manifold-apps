import SwiftUI
import ManifoldKit

/// Preset entries the Theming showcase's picker offers. Each maps to a
/// concrete ``ManifoldTheme`` value written straight into
/// ``AppEnvironment/theme`` — the cascading `.manifoldTheme(env.theme)`
/// modifier `RootView` already applies propagates the pick app-wide, to
/// every chat surface, not just this screen.
enum ThemingPreset: String, CaseIterable, Identifiable {
    case standard
    case classic
    case brand

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .classic: "Classic"
        case .brand: "Brand"
        }
    }

    /// The `ManifoldTheme` this preset writes into `AppEnvironment.theme`.
    /// `.standard`/`.classic` are the two presets `ManifoldTheme` itself
    /// ships (`ManifoldTheme.standard` / `.classic` — the 2026-refresh
    /// default and the pre-refresh restore, respectively). `.brand` mirrors
    /// core's own `Example/Advanced/DemoContentView.swift`
    /// `DemoChatTheme.brand` case (indigo gradient user bubble, 22pt corner
    /// radius, 14pt padding) — the "host applies its own brand" worked
    /// example from that demo, ported onto the `ManifoldTheme` seam this app
    /// actually threads through `RootView`.
    var theme: ManifoldTheme {
        switch self {
        case .standard:
            .standard
        case .classic:
            .classic
        case .brand:
            ManifoldTheme(
                chatTheme: ChatTheme(
                    userBubbleBackground: AnyShapeStyle(Color.indigo.gradient),
                    assistantBubbleBackground: AnyShapeStyle(.fill.quaternary),
                    cornerRadius: 22,
                    bubblePadding: 14
                ),
                accent: AnyShapeStyle(Color.indigo)
            )
        }
    }
}

/// Theme-showcase view for the Theming feature (manifold-apps W2 P6).
///
/// A segmented picker switches among ``ThemingPreset``s and writes the
/// selection into ``AppEnvironment/theme``; `RootView`'s existing
/// `.manifoldTheme(env.theme)` modifier cascades the change to every chat
/// surface in the app. A live preview pair of real `MessageBubbleView`s
/// (the same view `ChatView` renders in the actual conversation) makes the
/// change visible in place, without leaving this screen.
struct ThemingShowcaseView: View {
    let env: AppEnvironment

    @State private var preset: ThemingPreset = .standard

    private static let previewSessionID = UUID()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                picker
                preview
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Theming")
        .onChange(of: preset, initial: true) { _, newValue in
            env.theme = newValue.theme
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Theming")
                .font(.title2.bold())
            Text("Pick a preset to restyle the whole app. ManifoldKit's .manifoldTheme(_:) cascades from RootView to every chat surface below.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var picker: some View {
        Picker("Appearance", selection: $preset) {
            ForEach(ThemingPreset.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("theming-preset-picker")
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live preview")
                .font(.headline)

            VStack(spacing: 8) {
                MessageBubbleView(message: userPreviewMessage, isStreaming: false)
                MessageBubbleView(message: assistantPreviewMessage, isStreaming: false)
            }
            .environment(env.viewModel)

            Text("Bubble corner radius: \(Int(preset.theme.chatTheme.cornerRadius))pt")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("theming-corner-radius-label")
        }
        .padding(16)
        .background(preset.theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("theming-preview-surface")
    }

    private var userPreviewMessage: ChatMessage {
        ChatMessage(
            role: .user,
            content: "How does theming work?",
            sessionID: Self.previewSessionID
        )
    }

    private var assistantPreviewMessage: ChatMessage {
        ChatMessage(
            role: .assistant,
            content: "Every bubble reads its chrome from the active ManifoldTheme.",
            sessionID: Self.previewSessionID
        )
    }
}

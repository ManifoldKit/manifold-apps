import SwiftUI
import ManifoldKit

/// Copyable, live component examples and routes to Manifold's existing setup
/// screens. All displayed chat content is static UI documentation: it does not
/// claim to be a generated response or a tool execution transcript.
struct ExploreView: View {
    let env: AppEnvironment
    @Environment(\.exploreNavigationActions) private var navigationActions

    private static let previewSessionID = UUID()
    private static let messageBubbleSource = URL(
        string: "https://github.com/ManifoldKit/ManifoldKit/blob/0.77.0/Sources/ManifoldUI/Views/Chat/MessageBubbleView.swift"
    )!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                introduction
                componentExamples
                appearance
                setup
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
        }
        .navigationTitle("Explore")
        .accessibilityIdentifier("explore-root")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Explore Manifold", systemImage: "sparkles")
                .font(.title.bold())
            Text("Use these native components as a starting point, then configure a model or provider when you are ready to chat.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Every example here is rendered by the same public ManifoldKit UI components used by the chat experience.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("explore-introduction")
    }

    private var componentExamples: some View {
        ExploreCard(title: "Make it yours", subtitle: "Text, Markdown, and code are ordinary chat content.") {
            VStack(spacing: 10) {
                MessageBubbleView(message: userPreview, isStreaming: false)
                    .accessibilityLabel("Explore user example: Can a conversation include Markdown?")
                    .accessibilityIdentifier("explore-user-message")
                MessageBubbleView(message: assistantPreview, isStreaming: false)
                    .accessibilityLabel("Explore assistant example: Markdown and code")
                    .accessibilityIdentifier("explore-assistant-message")
            }
            .environment(env.viewModel)

            VStack(alignment: .leading, spacing: 6) {
                Label("Built with public components", systemImage: "curlybraces")
                    .font(.subheadline.weight(.semibold))
                Text("`MessageBubbleView` renders the conversation content, including Markdown and fenced code, while `ChatTheme` supplies its visual language.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link(destination: Self.messageBubbleSource) {
                    Label("View MessageBubbleView in ManifoldKit 0.77.0", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityIdentifier("explore-message-bubble-source")
            }
            .accessibilityIdentifier("explore-component-reference")
        }
    }

    private var appearance: some View {
        ExploreCard(title: "Appearance", subtitle: "A theme change applies through the same root cascade as chat.") {
            ThemingShowcaseContent(env: env)
                .accessibilityIdentifier("explore-theming-showcase")
        }
    }

    @ViewBuilder
    private var setup: some View {
        if let navigationActions {
            ExploreCard(title: "Set up Manifold", subtitle: "Choose a local model or configure a cloud provider using the existing app screens.") {
                HStack(alignment: .top, spacing: 12) {
                    Button(action: navigationActions.showModels) {
                        setupLabel(
                            title: "Models",
                            detail: "Browse, download, and manage local models.",
                            systemImage: "cpu"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("explore-show-models")

                    Button(action: navigationActions.showCloud) {
                        setupLabel(
                            title: "Cloud providers",
                            detail: "Add an API endpoint in the existing configuration screen.",
                            systemImage: "cloud"
                        )
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("explore-show-cloud")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func setupLabel(title: String, detail: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var userPreview: ChatMessage {
        ChatMessage(
            role: .user,
            content: "Can a conversation include Markdown?",
            sessionID: Self.previewSessionID
        )
    }

    private var assistantPreview: ChatMessage {
        ChatMessage(
            role: .assistant,
            content: "Yes. **Markdown** and code render as regular message content.\n\n```swift\nlet theme = ManifoldTheme.standard\n```",
            sessionID: Self.previewSessionID
        )
    }
}

private struct ExploreCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

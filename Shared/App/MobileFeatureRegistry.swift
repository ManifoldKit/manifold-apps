/// The feature set shown in the iOS `Manifold` app's sidebar. Order is
/// display order. No `MCPFeature` — the MCP client surface targets macOS
/// only in this repo's product split (see ``StudioFeatureRegistry``).
enum MobileFeatureRegistry {
    static let all: [any AppFeature.Type] = [
        ToolsFeature.self,
        ScenariosFeature.self,
        CloudFeature.self,
        AppIntentsFeature.self,
        ThemingFeature.self,
    ]
}

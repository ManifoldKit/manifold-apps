/// The feature set shown in the macOS `ManifoldStudio` app's sidebar.
/// Superset of ``MobileFeatureRegistry`` — adds `MCPFeature`, since the MCP
/// client surface targets macOS only in this repo's product split.
enum StudioFeatureRegistry {
    static let all: [any AppFeature.Type] = [
        ToolsFeature.self,
        ScenariosFeature.self,
        CloudFeature.self,
        MCPFeature.self,
        AppIntentsFeature.self,
        ThemingFeature.self,
    ]
}

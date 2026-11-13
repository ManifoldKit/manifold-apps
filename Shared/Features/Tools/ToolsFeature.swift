import SwiftUI

/// Installs the app's reference toolset and exposes a browser for the live
/// registry plus its approval policy.
enum ToolsFeature: AppFeature {
    static let id = "tools"
    static let title = "Tools"
    static let systemImage = "wrench.and.screwdriver"

    static func install(into env: AppEnvironment) {
        updateAdvertisement(in: env)
    }

    static func setSampleToolsEnabled(_ enabled: Bool, in env: AppEnvironment) {
        guard enabled != env.sampleToolsEnabled else { return }
        if enabled {
            ManifoldToolset.register(on: env.toolRegistry)
        } else {
            // Hiding schemas alone still leaves executors callable by the model.
            for name in ManifoldToolset.baselineNames {
                env.toolRegistry.unregister(name: name)
            }
            env.toolApprovalGate.resetForNewSession()
        }
        env.sampleToolsEnabled = enabled
        updateAdvertisement(in: env)
    }

    static func updateAdvertisement(in env: AppEnvironment) {
        guard env.sampleToolsEnabled else {
            // Independently registered AppIntent tools remain available.
            env.toolRegistry.advertisedToolNames = nil
            return
        }
        ManifoldToolset.updateAdvertisement(
            on: env.toolRegistry,
            backendName: env.viewModel.activeBackendName
        )
    }

    static func makeView(env: AppEnvironment) -> AnyView {
        AnyView(ToolsBrowserView(env: env))
    }
}

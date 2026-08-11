import SwiftUI
import SwiftData // needed for .modelContainer modifier type inference
import ManifoldKit

/// Manifold — the consumer chat app (iOS 18+).
///
/// Builds the shared `AppEnvironment` composition root and shows
/// `RootView`. Under `--uitesting`, `AppEnvironment.bootstrap` swaps in a
/// deterministic `ScriptedBackend` and an in-memory store — see
/// `Shared/App/AppEnvironment.swift`.
@main
struct ManifoldApp: App {
    @State private var env: AppEnvironment?
    @State private var startupError: Error?

    var body: some Scene {
        WindowGroup {
            if let env {
                RootView()
                    .environment(env)
                    .modelContainer(env.bootstrap.modelContainer)
            } else if let startupError {
                ContentUnavailableView {
                    Label("Failed to start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(String(describing: startupError))
                }
            } else {
                ProgressView("Starting…")
                    .task { await start() }
            }
        }
    }

    @MainActor
    private func start() async {
        do {
            env = try await AppEnvironment.bootstrap(
                storeName: "Manifold",
                appName: "Manifold",
                bundleIdentifier: "com.manifoldkit.Manifold"
            )
        } catch {
            self.startupError = error
        }
    }
}

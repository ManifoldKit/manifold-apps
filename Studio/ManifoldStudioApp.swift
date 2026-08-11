import SwiftUI
import SwiftData // needed for .modelContainer modifier type inference
import ManifoldKit

/// Manifold Studio — the macOS pro showcase app (macOS 15+).
///
/// Night-1 scaffold: same `ManifoldKit.quickStart()` wiring as the iOS
/// `Manifold` target. A composition root and shared Features move into
/// `Shared/` in a follow-up PR — this file stays intentionally thin until
/// then.
@main
struct ManifoldStudioApp: App {
    @State private var result: QuickStartResult?
    @State private var error: ManifoldKitError?
    @State private var showModelManagement = false

    var body: some Scene {
        WindowGroup {
            if let result {
                NavigationStack {
                    ChatView(showModelManagement: $showModelManagement)
                }
                .environment(result.viewModel)
                .modelContainer(result.bootstrap.modelContainer)
            } else if let error {
                ContentUnavailableView {
                    Label("Failed to start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.errorDescription ?? "Unknown error")
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
            result = try await ManifoldKit.quickStart(
                configuration: ManifoldConfiguration(
                    appName: "Manifold Studio",
                    bundleIdentifier: "com.manifoldkit.ManifoldStudio"
                )
            )
        } catch let e as ManifoldKitError {
            error = e
        } catch {
            self.error = .from(error)
        }
    }
}

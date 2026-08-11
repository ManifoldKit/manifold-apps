import SwiftUI
import SwiftData // needed for .modelContainer modifier type inference
import ManifoldKit

/// Manifold — the consumer chat app (iOS 18+).
///
/// Night-1 scaffold: `ManifoldKit.quickStart()` wires inference, persistence,
/// and a single-session chat surface in one call, mirroring core's
/// `MinimalExample`. A composition root and shared Features move into
/// `Shared/` in a follow-up PR — this file stays intentionally thin until
/// then.
@main
struct ManifoldApp: App {
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
                    appName: "Manifold",
                    bundleIdentifier: "com.manifoldkit.Manifold"
                )
            )
        } catch let e as ManifoldKitError {
            error = e
        } catch {
            self.error = .from(error)
        }
    }
}

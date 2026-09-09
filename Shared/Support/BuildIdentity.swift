import Foundation

/// The identity of the binary currently running, intended for support and
/// release diagnostics. The source revision is written into the processed
/// Info.plist by the target build phase so it is available in both Xcode and
/// `make` builds without relying on a runtime Git checkout.
struct BuildIdentity: Equatable, Sendable {
    let productName: String
    let marketingVersion: String
    let buildNumber: String
    let sourceRevision: String?

    init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary)
    }

    init(infoDictionary: [String: Any]?) {
        productName = Self.stringValue(for: "CFBundleDisplayName", in: infoDictionary)
            ?? Self.stringValue(for: "CFBundleName", in: infoDictionary)
            ?? "Manifold"
        marketingVersion = Self.stringValue(for: "CFBundleShortVersionString", in: infoDictionary)
            ?? "Unknown"
        buildNumber = Self.stringValue(for: "CFBundleVersion", in: infoDictionary)
            ?? "Unknown"
        sourceRevision = Self.sourceRevision(in: infoDictionary)
    }

    /// The concise binary identifier shown to a person inspecting the app.
    var displayName: String {
        "\(productName) \(marketingVersion) (\(buildNumber))"
    }

    /// Includes the source revision when the build was made from a Git
    /// checkout. Source archives and otherwise non-Git builds still expose a
    /// useful version/build identity without inventing a revision.
    var detailedDisplayName: String {
        guard let sourceRevision else { return displayName }
        return "\(displayName) • \(sourceRevision)"
    }

    private static func sourceRevision(in infoDictionary: [String: Any]?) -> String? {
        guard let rawRevision = stringValue(for: "ManifoldSourceRevision", in: infoDictionary),
              rawRevision.caseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }

        // A build override may provide a full SHA. Keep the on-device value
        // compact while retaining a `-dirty` suffix that distinguishes local
        // developer installs from the committed revision they began from.
        let components = rawRevision.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let commit = String(components[0].prefix(12))
        guard !commit.isEmpty else { return nil }
        guard components.count == 2 else { return commit }
        return "\(commit)-\(components[1])"
    }

    private static func stringValue(for key: String, in infoDictionary: [String: Any]?) -> String? {
        guard let value = infoDictionary?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

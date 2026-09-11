import XCTest

final class BuildIdentityTests: XCTestCase {

    func test_detailedDisplayName_includesVersionBuildAndShortSourceRevision() {
        let identity = BuildIdentity(infoDictionary: [
            "CFBundleDisplayName": "Manifold",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "2",
            "ManifoldSourceRevision": "42c3445f6e8d9a0b1c2d3e4f5a6b7c8d-dirty"
        ])

        XCTAssertEqual(identity.displayName, "Manifold 0.1.0 (2)")
        XCTAssertEqual(identity.detailedDisplayName, "Manifold 0.1.0 (2) • 42c3445f6e8d-dirty")
    }

    func test_detailedDisplayName_omitsUnavailableSourceRevisionWithoutHidingVersionOrBuild() {
        let identity = BuildIdentity(infoDictionary: [
            "CFBundleName": "Manifold",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "2",
            "ManifoldSourceRevision": "unknown"
        ])

        XCTAssertNil(identity.sourceRevision)
        XCTAssertEqual(identity.detailedDisplayName, "Manifold 0.1.0 (2)")
    }

    func test_init_usesExplicitFallbacksWhenBundleMetadataIsMissing() {
        let identity = BuildIdentity(infoDictionary: nil)

        XCTAssertEqual(identity.displayName, "Manifold Unknown (Unknown)")
        XCTAssertNil(identity.sourceRevision)
    }
}

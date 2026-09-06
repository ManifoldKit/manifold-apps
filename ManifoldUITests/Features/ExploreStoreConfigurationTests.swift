import XCTest

final class ExploreStoreConfigurationTests: XCTestCase {
    func testPersistentStoreOptInRequiresUITesting() throws {
        XCTAssertNil(try LaunchArguments.persistenceTestRunID(
            arguments: [], environment: ["MANIFOLD_UI_TEST_STORE_ID": "invalid"]
        ))
    }

    func testMalformedOptInFailsInsteadOfUsingAnotherStore() {
        XCTAssertThrowsError(try LaunchArguments.persistenceTestRunID(
            arguments: ["--uitesting"],
            environment: ["MANIFOLD_UI_TEST_STORE_ID": "../../production"]
        ))
    }

    func testParsesStableRunIdentity() throws {
        let id = UUID()
        let environment = ["MANIFOLD_UI_TEST_STORE_ID": id.uuidString]
        XCTAssertEqual(try LaunchArguments.persistenceTestRunID(
            arguments: ["--uitesting"], environment: environment
        ), id)
    }

    func testOrdinaryUITestingRetainsEphemeralStore() throws {
        XCTAssertNil(try LaunchArguments.persistenceTestRunID(
            arguments: ["--uitesting"], environment: [:]
        ))
    }
}

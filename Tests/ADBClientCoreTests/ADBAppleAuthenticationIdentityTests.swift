#if canImport(Security)
import XCTest
@testable import ADBClientCore

final class ADBAppleAuthenticationIdentityTests: XCTestCase {
    func testStoreKeepsConfiguration() {
        let store = ADBAppleAuthenticationIdentityStore(
            applicationTag: "com.adbtv.tests.identity",
            publicKeyComment: "tester@adbtv",
            synchronizable: false
        )

        XCTAssertEqual(store.applicationTag, "com.adbtv.tests.identity")
        XCTAssertEqual(store.publicKeyComment, "tester@adbtv")
        XCTAssertFalse(store.synchronizable)
    }
}
#endif

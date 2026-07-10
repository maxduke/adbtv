import XCTest
@testable import ADBClientCore

final class ADBCommandTests: XCTestCase {
    func testWireNamesUseADBByteOrder() {
        XCTAssertEqual(ADBCommand.connect.wireName, "CNXN")
        XCTAssertEqual(ADBCommand.auth.wireName, "AUTH")
        XCTAssertEqual(ADBCommand.secureTLS.wireName, "STLS")
        XCTAssertEqual(ADBCommand.open.wireName, "OPEN")
        XCTAssertEqual(ADBCommand.okay.wireName, "OKAY")
        XCTAssertEqual(ADBCommand.close.wireName, "CLSE")
        XCTAssertEqual(ADBCommand.write.wireName, "WRTE")
    }
}

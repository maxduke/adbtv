import XCTest
@testable import ADBClientCore

final class ADBShellCommandTests: XCTestCase {
    func testBuildsShellServiceName() throws {
        let command = try ADBShellCommand("getprop ro.product.model")

        XCTAssertEqual(command.rawValue, "getprop ro.product.model")
        XCTAssertEqual(command.serviceName, "shell:getprop ro.product.model")
    }

    func testRejectsEmptyCommand() {
        XCTAssertThrowsError(try ADBShellCommand("")) { error in
            XCTAssertEqual(error as? ADBShellCommandError, .emptyCommand)
        }
    }

    func testRejectsNullByte() {
        XCTAssertThrowsError(try ADBShellCommand("echo \u{0}")) { error in
            XCTAssertEqual(error as? ADBShellCommandError, .containsNullByte)
        }
    }
}

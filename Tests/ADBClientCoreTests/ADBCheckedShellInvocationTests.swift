#if os(macOS) || os(Linux)
import Foundation
import XCTest
@testable import ADBClientCore

final class ADBCheckedShellInvocationTests: XCTestCase {
    func testExplicitExitPreservesOutputAndExitCode() throws {
        let result = try execute("printf 'before exit'; exit 7")

        XCTAssertEqual(result.output.utf8String, "before exit")
        XCTAssertEqual(result.exitCode, 7)
    }

    func testTrailingCommentCannotConsumeStatusMarker() throws {
        let result = try execute("printf 'output' # an ordinary comment")

        XCTAssertEqual(result.output.utf8String, "output")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testTrailingBackgroundOperatorRemainsValidShellSyntax() throws {
        XCTAssertEqual(try execute("true &").exitCode, 0)
    }

    func testExitTrapRunsBeforeStatusIsCollected() throws {
        let result = try execute("trap 'printf restored' EXIT; exit 24")

        XCTAssertEqual(result.output.utf8String, "restored")
        XCTAssertEqual(result.exitCode, 24)
    }

    func testMultilineCommandAndQuotesRemainIntact() throws {
        let result = try execute("value=\"a'b\"\nprintf '%s' \"$value\"\nfalse\n")

        XCTAssertEqual(result.output.utf8String, "a'b")
        XCTAssertEqual(result.exitCode, 1)
    }

    private func execute(_ command: String) throws -> ADBCheckedShellResult {
        let invocation = try ADBCheckedShellInvocation(command: ADBShellCommand(command))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", invocation.shellCommand.rawValue]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try invocation.result(from: ADBShellOutput(bytes: Array(bytes)))
    }
}
#endif

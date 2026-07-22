import ADBClientCore
import XCTest
@testable import ADBTVApp

final class ADBTVRemoteOperationTests: XCTestCase {
    func testSendActionRequiresSelectedDevice() async throws {
        var connection = RecordingRemoteConnection()

        await XCTAssertThrowsADBTVRemoteOperationError({
            try await ADBTVRemoteOperation().sendAction(
                .home,
                from: ADBTVAppModel(),
                using: &connection
            )
        },
            .missingDevice
        )
    }

    func testSendActionCallsConnectionWithAction() async throws {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var connection = RecordingRemoteConnection(output: ADBShellOutput(bytes: Array("ok\n".utf8)))

        let output = try await ADBTVRemoteOperation().sendAction(
            .settings,
            from: ADBTVAppModel(devices: [device]),
            using: &connection
        )

        XCTAssertEqual(output.utf8String, "ok\n")
        XCTAssertEqual(connection.actions, [.settings])
    }

    func testSendTextCallsConnectionWithValidatedText() async throws {
        let device = ADBTVDeviceSummary(displayName: "TV", host: "192.168.1.50", port: 5555)
        var connection = RecordingRemoteConnection(output: ADBShellOutput(bytes: Array("ok\n".utf8)))
        let text = try ADBTVRemoteText("hello tv")

        let output = try await ADBTVRemoteOperation().sendText(
            text,
            from: ADBTVAppModel(devices: [device]),
            using: &connection
        )

        XCTAssertEqual(output.utf8String, "ok\n")
        XCTAssertEqual(connection.texts, [text])
    }
}

private struct RecordingRemoteConnection: ADBTVRemoteConnection {
    var output: ADBShellOutput
    private(set) var actions: [ADBTVRemoteAction]
    private(set) var texts: [ADBTVRemoteText]

    init(output: ADBShellOutput = ADBShellOutput(bytes: [])) {
        self.output = output
        self.actions = []
        self.texts = []
    }

    mutating func sendRemoteAction(_ action: ADBTVRemoteAction) async throws -> ADBShellOutput {
        actions.append(action)
        return output
    }

    mutating func sendRemoteText(_ text: ADBTVRemoteText) async throws -> ADBShellOutput {
        texts.append(text)
        return output
    }

    func cancel() {}
}

private func XCTAssertThrowsADBTVRemoteOperationError<T>(
    _ expression: () async throws -> T,
    _ expectedError: ADBTVRemoteOperationError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expectedError) to be thrown.", file: file, line: line)
    } catch let error as ADBTVRemoteOperationError {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("Expected \(expectedError), got \(error).", file: file, line: line)
    }
}

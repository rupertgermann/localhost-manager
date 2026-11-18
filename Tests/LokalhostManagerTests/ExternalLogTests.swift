import XCTest
@testable import LokalhostManager

final class ExternalLogTests: XCTestCase {
    func testLogDisplaysMissingEmptyAndLatestOutputFromConfiguredFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }

        guard case .unavailable = FileLog.read(path: nil),
              case .unavailable = FileLog.read(path: file.path) else { return XCTFail("Missing source") }
        try Data().write(to: file)
        XCTAssertEqual(FileLog.read(path: file.path), .empty)
        let output = String(repeating: "a", count: 100_000) + "\nNeueste Ausgabe"
        try Data(output.utf8).write(to: file)
        guard case .output(let text, true) = FileLog.read(path: file.path) else { return XCTFail("Expected a bounded tail") }
        XCTAssertTrue(text.hasSuffix("\nNeueste Ausgabe"))
        XCTAssertLessThan(text.utf8.count, output.utf8.count)
    }
}

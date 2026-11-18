import XCTest
@testable import LokalhostManager

final class WebTargetTests: XCTestCase {
    func testOnlyLocalHTTPAddressesOnActiveBindingsCanOpen() throws {
        let bindings = [HostBinding(family: "IPv4", host: "*", port: 8123)]
        for address in ["http://localhost:8123/status", "https://127.0.0.1:8123/"] {
            XCTAssertTrue(WebTarget.accepts(try XCTUnwrap(URL(string: address)), on: bindings))
        }
        for address in ["http://localhost:8124", "ftp://localhost:8123", "http://example.com:8123", "http://127.0.0.1@example.com:8123", "http://[::1]:8123"] {
            XCTAssertFalse(WebTarget.accepts(try XCTUnwrap(URL(string: address)), on: bindings))
        }
    }
}

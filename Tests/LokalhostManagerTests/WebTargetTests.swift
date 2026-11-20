import XCTest
@testable import LokalhostManager

final class WebTargetTests: XCTestCase {
    func testBrowserLinksUseReachableHostAndPublishedPort() throws {
        let v4 = HostBinding(family: "IPv4", host: "*", port: 3000)
        let v6 = HostBinding(family: "IPv6", host: "::", port: 3001)
        let lan = HostBinding(family: "IPv4", host: "192.168.1.8", port: 443)
        let saved = try XCTUnwrap(URL(string: "https://localhost:3000/admin"))
        XCTAssertEqual(WebTarget.browserURL(for: v4, saved: [])?.absoluteString, "http://127.0.0.1:3000")
        XCTAssertEqual(WebTarget.browserURL(for: v6, saved: [saved])?.absoluteString, "http://[::1]:3001")
        XCTAssertEqual(WebTarget.browserURL(for: lan, saved: [])?.absoluteString, "https://192.168.1.8:443")
        XCTAssertEqual(WebTarget.browserURL(for: v4, saved: [saved]), saved)
        XCTAssertEqual(WebTarget.browserURL(for: v4, saved: [], containerPort: "443/tcp")?.absoluteString, "https://127.0.0.1:3000")
        XCTAssertNil(WebTarget.browserURL(for: v4, saved: [saved], containerPort: "53/udp"))
    }

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

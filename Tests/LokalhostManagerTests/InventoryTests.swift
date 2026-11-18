import Darwin
import XCTest
@testable import LokalhostManager

final class InventoryTests: XCTestCase {
    func testTwoLoopbackListenersBelongToOneProcess() async throws {
        var ports = Set<Int>()
        var descriptors: [Int32] = []
        defer { for fd in descriptors { close(fd) } }
        for _ in 0..<2 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            descriptors.append(fd)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(address.sin_len)
            withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    XCTAssertEqual(Darwin.bind(fd, $0, length), 0)
                    XCTAssertEqual(listen(fd, 1), 0)
                    XCTAssertEqual(getsockname(fd, $0, &length), 0)
                }
            }
            ports.insert(Int(UInt16(bigEndian: address.sin_port)))
        }
        let inventory = try await ListenerInventory.scan()
        let listener = try XCTUnwrap(inventory.listeners.first { $0.pid == getpid() })
        XCTAssertEqual(listener.identity?.uid, getuid())
        XCTAssertTrue(ports.isSubset(of: Set(listener.bindings.map(\.port))))
        XCTAssertEqual(ports.count, 2)
    }
}

import Darwin
import XCTest
@testable import LokalhostManager

final class InventoryTests: XCTestCase {
    @MainActor
    func testFailedInventoryRetainsRowsBlocksActionsAndRecoversToConfirmedEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(dataDirectory: directory)
        await store.load()
        let marker = directory.appendingPathComponent("started")
        let service = ServiceRecord(name: "API", directory: directory.path, startCommand: "touch started")
        try await store.save(Catalog(services: [service]))
        let listener = LocalListener(pid: 42, name: "Test")
        await store.refresh { ListenerInventory(listeners: [listener], warning: nil) }
        await store.refresh { throw ManagerError("lsof fehlgeschlagen") }
        XCTAssertEqual(store.inventory.listeners.map(\.pid), [42])
        XCTAssertEqual(store.inventory.visibility, .unavailable)
        await store.perform(.start, row: ServiceRow(record: service))
        XCTAssertTrue(store.message?.contains("lsof") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        await store.refresh { ListenerInventory(listeners: [listener], warning: "Eingeschränkt", visibility: .partial) }
        XCTAssertEqual(store.inventory.visibility, .partial)
        XCTAssertEqual(store.inventory.listeners.count, 1)
        XCTAssertThrowsError(try store.inventory.requireCurrent())
        await store.refresh { ListenerInventory(listeners: [], warning: nil) }
        XCTAssertTrue(store.inventory.listeners.isEmpty)
        XCTAssertEqual(store.inventory.visibility, .current)
    }

    func testPortConflictsUseAddressesFamiliesAndLegacySnapshots() throws {
        let loopback = HostBinding(family: "IPv4", host: "127.0.0.1", port: 8090)
        func owner(_ family: String, _ host: String) -> LocalListener {
            LocalListener(pid: 42, name: "Listener", bindings: [HostBinding(family: family, host: host, port: 8090)])
        }
        let previous = Predecessor(processes: [], ports: [loopback])
        XCTAssertNoThrow(try previous.checkPorts([owner("IPv4", "127.0.0.2"), owner("IPv6", "[::1]")]))
        XCTAssertThrowsError(try previous.checkPorts([owner("IPv6", "::")]))
        XCTAssertThrowsError(try previous.checkPorts([owner("IPv6", "::ffff:127.0.0.1")]))
        XCTAssertThrowsError(try previous.checkPorts([owner("IPv4", "*")]))
        XCTAssertThrowsError(try previous.checkPorts([owner("IPv4", "0.0.0.0")]))
        let v6 = Predecessor(processes: [], ports: [HostBinding(family: "IPv6", host: "[::1]", port: 8090)])
        XCTAssertThrowsError(try v6.checkPorts([owner("IPv6", "::")]))
        XCTAssertThrowsError(try v6.checkPorts([owner("IPv6", "0:0:0:0:0:0:0:1")]))
        let legacy = try JSONDecoder().decode(Predecessor.self, from: Data(#"{"processes":[],"ports":[8090]}"#.utf8))
        XCTAssertThrowsError(try legacy.checkPorts([owner("IPv6", "::1")]))
        XCTAssertThrowsError(try legacy.checkPorts([owner("IPv4", "127.0.0.2")]))
        let mapped = try JSONDecoder().decode(HostBinding.self, from: Data(#"{"family":"IPv6","host":"127.0.0.1","port":8090}"#.utf8))
        XCTAssertEqual(mapped, loopback)
    }

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
        XCTAssertEqual(inventory.visibility, .current)
        let listener = try XCTUnwrap(inventory.listeners.first { $0.pid == getpid() })
        XCTAssertEqual(listener.identity?.uid, getuid())
        XCTAssertTrue(ports.isSubset(of: Set(listener.bindings.map(\.port))))
        XCTAssertEqual(ports.count, 2)
    }

    func testNetworkMountAndItsSymlinkAreExcludedFromLocalPaths() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }

        let localRoot = physicalDirectory(folder.path)
        let share = localRoot + "/Network Share"
        let link = localRoot + "/link"
        try files.createSymbolicLink(atPath: link, withDestinationPath: "Network Share")
        let networkID = fsid_t(val: (42, 1))
        let volumes = LocalVolumes(networkMounts: [(networkID, share)])

        XCTAssertTrue(volumes.isNetworkFileSystem(networkID))
        XCTAssertNil(volumes.resolveLocalPath(share + "/project"))
        XCTAssertNil(volumes.resolveLocalPath(localRoot + "/network share/project"))
        XCTAssertNil(volumes.resolveLocalPath(link + "/project"))
        XCTAssertEqual(volumes.resolveLocalPath(share + " Local"), share + " Local")
        XCTAssertEqual(volumes.resolveLocalPath(folder.path), localRoot)
    }

    func testIPv4MappedListenerIsReportedWithItsReachableIPv4Address() async throws {
        let fd = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::ffff:127.0.0.1", &address.sin6_addr), 1)
        var length = socklen_t(address.sin6_len)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(fd, $0, length), 0)
                XCTAssertEqual(listen(fd, 1), 0)
                XCTAssertEqual(getsockname(fd, $0, &length), 0)
            }
        }

        let listeners = try await ListenerInventory.currentListeners()
        let listener = try XCTUnwrap(listeners.first { $0.pid == getpid() })
        let port = Int(UInt16(bigEndian: address.sin6_port))
        XCTAssertTrue(listener.bindings.contains(HostBinding(family: "IPv4", host: "127.0.0.1", port: port)))
    }
}

import XCTest
@testable import LokalhostManager

final class DockerTests: XCTestCase {
    func testInspectPreservesPublishedAddressesProtocolsAndComposeInstance() throws {
        let json = #"""
        {"id":"123","name":"/shop-web-2","state":"running","project":"shop","service":"web","number":"2","workingDirectory":"/src/shop","oneoff":"False","ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"18080"},{"HostIp":"::","HostPort":"18080"}],"53/udp":[{"HostIp":"127.0.0.1","HostPort":"1053"}],"6379/tcp":null}}
        """#
        let container = try JSONDecoder().decode(DockerContainer.self, from: Data(json.utf8))
        XCTAssertEqual(container.name, "shop-web-2")
        XCTAssertEqual(container.ports.map(\.description).sorted(), ["0.0.0.0:18080 → 80/tcp", "127.0.0.1:1053 → 53/udp", "[::]:18080 → 80/tcp"])
        let inventory = DockerInventory(containers: [container], available: true)
        var row = try XCTUnwrap(inventory.rows(socket: "/test.sock", catalog: Catalog(), showStopped: false).first)
        XCTAssertTrue(row.webTargets.isEmpty)
        let confirmed = try XCTUnwrap(URL(string: "https://127.0.0.1:18080/app"))
        row.editableRecord.webTargets = [confirmed, try XCTUnwrap(URL(string: "http://127.0.0.1:1053"))]
        XCTAssertEqual(row.webTargets, [confirmed])
        XCTAssertEqual(container.instanceDescription, "shop / web · Instanz 2")
    }
    func testOnlySelectedLocalSocketReachesCLIAndHungInventoryFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let program = directory.appendingPathComponent("docker")
        let script = """
        #!/bin/sh
        [ -z "$DOCKER_CONTEXT$DOCKER_HOST$DOCKER_TLS_VERIFY$DOCKER_CONFIG" ] || exit 12
        [ "$1" = --host ] && [ "$2" = unix:///chosen.sock ] || exit 13
        if [ "$3" = hang ]; then exec /bin/sleep 8; fi
        """
        try script.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let cli = DockerCLI(socket: "/chosen.sock", executable: program.path)
        let containers = try await cli.scan()
        XCTAssertTrue(containers.isEmpty)
        do {
            _ = try await cli.run(["hang"], timeout: 0.2)
            XCTFail("Hanging CLI should report its timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Zeitüberschreitung")) }
        do {
            _ = try await DockerCLI(socket: "tcp://remote:2375", executable: program.path).scan()
            XCTFail("Remote endpoint should be rejected before launch")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Unix-Socket")) }
    }

    func testSavedInstanceTracksComposeRecreationAndKeepsRemovedStandaloneMissing() throws {
        func container(_ id: String, _ labels: String = "") throws -> DockerContainer {
            let json = #"{"id":"ID","name":"web","state":"exited","ports":nullLABELS}"#
                .replacingOccurrences(of: "ID", with: id).replacingOccurrences(of: "LABELS", with: labels)
            return try JSONDecoder().decode(DockerContainer.self, from: Data(json.utf8))
        }
        let labels = #","project":"shop","service":"web","number":"1""#
        let socket = "/test.sock"
        var inventory = DockerInventory(containers: [try container("old", labels), try container("solo")], available: true)
        var catalog = Catalog()
        let projectID = UUID()
        let rows = inventory.rows(socket: socket, catalog: catalog, showStopped: true)
        catalog.docker = rows.map {
            var record = $0.editableRecord
            record.projectID = projectID
            return record
        }
        inventory.containers = [try container("replacement", labels), try container("same-name")]
        let saved = inventory.rows(socket: socket, catalog: catalog, showStopped: false)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.compactMap { $0.current?.id }, ["replacement"])
        XCTAssertTrue(saved.allSatisfy { $0.projectID == projectID })
        XCTAssertTrue(saved.contains { $0.status == "Container fehlt" })
        inventory.available = false
        let unknown = inventory.rows(socket: socket, catalog: catalog, showStopped: false)
        XCTAssertTrue(unknown.allSatisfy { $0.status == "Unbekannt" && $0.current == nil })
    }
    func testManualMappingDuringDuplicateReplicaSurvivesOnlyWithSelectedID() throws {
        func replica(_ id: String) throws -> DockerContainer {
            let json = #"{"id":"ID","name":"web","state":"running","project":"app","service":"web","number":"1"}"#
            return try JSONDecoder().decode(DockerContainer.self, from: Data(json.replacingOccurrences(of: "ID", with: id).utf8))
        }
        let first = try replica("first"), second = try replica("second")
        var inventory = DockerInventory(containers: [first, second], available: true)
        var catalog = Catalog()
        func rows() -> [DockerRow] { inventory.rows(socket: "/test", catalog: catalog, showStopped: true) }
        let project = UUID()
        inventory.containers = [first]
        var compose = try XCTUnwrap(rows().first?.editableRecord)
        compose.projectID = UUID()
        inventory.containers = [first, second]
        var selected = try XCTUnwrap(rows().first { $0.current?.id == first.id }?.editableRecord)
        selected.projectID = project
        catalog.docker = [selected, compose]
        inventory.containers = [first]
        XCTAssertEqual(rows().count, 1)
        XCTAssertEqual(rows().first?.projectID, project)
        inventory.containers = [second]
        XCTAssertEqual(rows().first { $0.current != nil }?.projectID, compose.projectID)
        XCTAssertEqual(rows().first { $0.current == nil }?.projectID, project)
    }

    func testOnlyConfirmedMatchingForwarderBindingIsHidden() throws {
        let json = #"{"id":"current","name":"/site","state":"running","ports":{"80/tcp":[{"HostIp":"::","HostPort":"8080"}]}}"#
        let site = try JSONDecoder().decode(DockerContainer.self, from: Data(json.utf8))
        var inventory = DockerInventory(containers: [site], available: true)
        let matches = HostBinding(family: "IPv6", host: "*", port: 8080)
        let keep = HostBinding(family: "IPv4", host: "127.0.0.1", port: 8080)
        let backend = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
        var listener = LocalListener(pid: 4, name: "com.docker.backend", executable: backend, bindings: [matches, keep])
        XCTAssertEqual(inventory.nativeListeners([listener]).first?.bindings, [keep])
        listener.executable = "/tmp/com.docker.backend"
        XCTAssertEqual(inventory.nativeListeners([listener]).first?.bindings, [matches, keep])
        listener.executable = backend
        inventory.available = false
        XCTAssertEqual(inventory.nativeListeners([listener]).first?.bindings, [matches, keep])
    }
}

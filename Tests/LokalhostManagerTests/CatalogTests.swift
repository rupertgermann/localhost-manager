import XCTest
@testable import LokalhostManager

final class CatalogTests: XCTestCase {
    func testExistingProjectAndServiceUseTheSamePhysicalDirectoryAsTheListener() throws {
        let name = "lokalhost-path-" + UUID().uuidString
        let folder = URL(fileURLWithPath: "/private/tmp/" + name)
        let child = folder.appendingPathComponent("Frontend")
        let alias = "/tmp/" + name
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let project = Project(name: "Website", directory: alias)
        let saved = ServiceRecord(name: "Gespeichertes Frontend", directory: alias + "/Frontend", executable: "/bin/node")
        let container = DockerRecord(socket: "/local.sock", key: .container("test"), name: "db",
                                     instance: "db", directory: alias)
        let old = Catalog(projects: [project], services: [saved], docker: [container])
        let file = folder.appendingPathComponent("catalog.json")
        try JSONEncoder().encode(old).write(to: file)
        let catalog = try Catalog.read(from: file)
        let listener = LocalListener(pid: 42, name: "node", directory: child.path, executable: "/bin/node")
        let rows = catalog.rows(for: [listener])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.record?.id, saved.id)
        XCTAssertEqual(rows.first?.projectID, project.id)
        XCTAssertEqual(catalog.docker?.first?.directory, folder.path)
    }

    func testManualAssignmentSurvivesRefreshAndDoesNotClaimAnotherServiceSharingItsPort() throws {
        let project = Project(name: "Website", directory: "/work/site")
        let alternate = Project(name: "Werkzeuge", directory: "/tools")
        let identity = ProcessIdentity(pid: 42, uid: 501, seconds: 10, microseconds: 2)
        let listener = LocalListener(pid: 42, name: "Frontend", identity: identity, directory: "/work/site/client", executable: "/bin/node", bindings: [HostBinding(family: "IPv4", host: "*", port: 8080)])
        var catalog = Catalog(projects: [project, alternate])
        let initial = try XCTUnwrap(catalog.rows(for: [listener]).first)
        XCTAssertEqual(initial.projectID, project.id)
        var record = initial.editableRecord
        record.projectID = alternate.id
        catalog.services = [record]
        let assigned = try XCTUnwrap(catalog.rows(for: [listener]).first)
        XCTAssertEqual(assigned.projectID, alternate.id)
        var other = listener
        other.identity?.seconds += 1
        other.directory = "/work/site-copy"
        let result = catalog.rows(for: [other])
        XCTAssertNil(result.first { $0.listener != nil }?.projectID)
        XCTAssertNil(result.first { $0.record?.id == record.id }?.listener)
    }
}

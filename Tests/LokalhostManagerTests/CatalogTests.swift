import XCTest
@testable import LokalhostManager

final class CatalogTests: XCTestCase {
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

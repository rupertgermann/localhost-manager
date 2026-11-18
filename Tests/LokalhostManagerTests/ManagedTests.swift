import XCTest
@testable import LokalhostManager

final class ManagedTests: XCTestCase {
    func testEnvValuesAreLiteralAndParseErrorsHideSecrets() throws {
        let env = try ManagedEnvironment.parse("# local\nTOKEN='$(echo abc)'\nEMPTY=\nWITH_EQUALS=a=b\n")
        XCTAssertEqual(env, ["TOKEN": "$(echo abc)", "EMPTY": "", "WITH_EQUALS": "a=b"])
        XCTAssertThrowsError(try ManagedEnvironment.parse("A=ok\nSECRET VALUE")) {
            XCTAssertTrue($0.localizedDescription.contains("Zeile 2"))
            XCTAssertFalse($0.localizedDescription.contains("SECRET"))
        }
    }

    func testMissingEnvAndMissingProgramHaveDistinctStartErrors() throws {
        guard ProcessInfo.processInfo.environment["LOKALHOST_TEST_LAUNCHD"] == "1" else {
            throw XCTSkip("Benötigt eine lokale macOS-GUI-Anmeldung mit launchd.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Start Errors \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jobs = ManagedJobs(directory: folder)
        var record = ServiceRecord(name: "Fehlstart", directory: folder.path, startCommand: "./missing-program", envFile: "missing.env")
        XCTAssertThrowsError(try jobs.start(record)) { XCTAssertTrue($0.localizedDescription.contains("missing.env")) }
        XCTAssertNil(try jobs.status(record.id))
        record.envFile = nil
        defer { if let state = try? jobs.status(record.id) { try? jobs.bootout(state.run) } }
        XCTAssertThrowsError(try jobs.start(record)) { XCTAssertTrue($0.localizedDescription.contains("Programm nicht gefunden"), $0.localizedDescription) }
        XCTAssertEqual(try jobs.status(record.id)?.exitCode, 127)
    }

    func testTransientJobSurvivesManagerRecreationAndDoesNotAutostart() async throws {
        guard ProcessInfo.processInfo.environment["LOKALHOST_TEST_LAUNCHD"] == "1" else {
            throw XCTSkip("Benötigt eine lokale macOS-GUI-Anmeldung mit launchd.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Managed Test \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let interpreter = folder.appendingPathComponent("project interpreter")
        let script = #"""
        #!/usr/bin/perl
        use IO::Socket::INET;
        $|=1;
        my $s=IO::Socket::INET->new(LocalAddr=>'127.0.0.1', LocalPort=>0, Listen=>1) or die;
        print "$ENV{MARK} ".$s->sockport."\n";
        while (my $client=$s->accept) { print STDERR "after reopen\n"; close $client }
        """#
        try script.write(to: interpreter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: interpreter.path)
        try "MARK=managed-start".write(to: folder.appendingPathComponent("test.env"), atomically: true, encoding: .utf8)
        let record = ServiceRecord(name: "API", directory: folder.path, startCommand: "'./project interpreter'; exit $?", envFile: "test.env")
        let data = folder.appendingPathComponent("Private Data", isDirectory: true)
        let jobs = ManagedJobs(directory: data)
        try jobs.start(record)
        let state = try XCTUnwrap(try jobs.status(record.id))
        defer { _ = try? jobs.bootout(state.run) }
        XCTAssertTrue(state.isRunning)
        XCTAssertThrowsError(try jobs.start(record))
        let reopened = ManagedJobs(directory: data)
        let inventory = try await ListenerInventory.scan()
        let rows = Catalog(services: [record]).rows(for: inventory.listeners, managed: [record.id: try XCTUnwrap(try reopened.status(record.id, listeners: inventory.listeners))])
        let row = try XCTUnwrap(rows.first { $0.record?.id == record.id })
        let port = try XCTUnwrap(row.listener?.bindings.first?.port)
        XCTAssertNotEqual(state.identity?.pid, row.listener?.pid)
        XCTAssertEqual(try String(contentsOf: reopened.log(state.run, stderr: false)).trimmingCharacters(in: .whitespacesAndNewlines), "managed-start \(port)")
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        client.arguments = ["-z", "-w", "1", "127.0.0.1", String(port)]
        try client.run()
        client.waitUntilExit()
        XCTAssertEqual(client.terminationStatus, 0)
        XCTAssertTrue(try String(contentsOf: reopened.log(state.run, stderr: true)).contains("after reopen"))
        try jobs.bootout(state.run)
        let cold = try XCTUnwrap(try reopened.status(record.id))
        XCTAssertFalse(cold.isRunning)
        XCTAssertEqual(cold.run.id, state.run.id)
        XCTAssertTrue(try String(contentsOf: reopened.log(cold.run, stderr: true)).contains("after reopen"))
    }
}

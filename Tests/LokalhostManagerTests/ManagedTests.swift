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

    func testMissingEnvAndMissingProgramHaveDistinctStartErrors() async throws {
        guard ProcessInfo.processInfo.environment["LOKALHOST_TEST_LAUNCHD"] == "1" else {
            throw XCTSkip("Benötigt eine lokale macOS-GUI-Anmeldung mit launchd.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Start Errors \(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jobs = ManagedJobs(directory: folder)
        var record = ServiceRecord(name: "Fehlstart", directory: folder.path, startCommand: "./missing-program", envFile: "missing.env")
        do {
            try await jobs.perform(.start, row: ServiceRow(record: record))
            XCTFail("Start sollte fehlschlagen.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("missing.env"), error.localizedDescription) }
        XCTAssertNil(try jobs.status(record.id))
        record.envFile = nil
        defer { if let state = try? jobs.status(record.id) { try? jobs.bootout(state.run) } }
        do {
            try await jobs.perform(.start, row: ServiceRow(record: record))
            XCTFail("Start sollte fehlschlagen.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Programm nicht gefunden"), error.localizedDescription) }
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
        try await jobs.perform(.start, row: ServiceRow(record: record))
        let state = try XCTUnwrap(try jobs.status(record.id))
        defer { _ = try? jobs.bootout(state.run) }
        XCTAssertTrue(state.isRunning)
        do {
            try await jobs.perform(.start, row: ServiceRow(record: record))
            XCTFail("Der Dienst läuft bereits")
        } catch { XCTAssertTrue(error.localizedDescription.contains("läuft")) }
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
        try "MARK=second-run".write(to: folder.appendingPathComponent("test.env"), atomically: true, encoding: .utf8)
        let attempts = await withTaskGroup(of: Result<Void, Error>.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { try await reopened.perform(.restart, row: row); return .success(()) }
                    catch { return .failure(error) }
                }
            }
            var outcomes: [Result<Void, Error>] = []
            for await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        XCTAssertEqual(attempts.filter { if case .success = $0 { return true }; return false }.count, 1)
        XCTAssertTrue(attempts.contains { if case let .failure(error) = $0 { return error.localizedDescription.contains("Aktion") }; return false })
        let nextInventory = try await ListenerInventory.scan()
        let next = try XCTUnwrap(try reopened.status(record.id, listeners: nextInventory.listeners))
        defer { _ = try? jobs.bootout(next.run) }
        XCTAssertNotEqual(state.run.id, next.run.id)
        XCTAssertNil(ProcessIdentity.read(try XCTUnwrap(row.listener?.pid)))
        XCTAssertTrue(try String(contentsOf: reopened.log(next.run, stderr: false)).hasPrefix("second-run "))
        XCTAssertTrue(try String(contentsOf: reopened.log(state.run, stderr: false)).hasPrefix("managed-start "))
        let nextRow = ServiceRow(record: record, listener: next.listeners.first, managed: next)
        try await reopened.perform(.stop, row: nextRow)
        XCTAssertNil(ProcessIdentity.read(try XCTUnwrap(next.identity?.pid)))
        XCTAssertNil(ProcessIdentity.read(try XCTUnwrap(nextRow.listener?.pid)))
        let cold = try XCTUnwrap(try reopened.status(record.id))
        XCTAssertFalse(cold.isRunning)
        XCTAssertEqual(cold.run.id, next.run.id)
        let conflict = try ListenerFixture(port: try XCTUnwrap(nextRow.bindings.first?.port))
        defer { conflict.close() }
        do {
            try await reopened.perform(.start, row: ServiceRow(record: record, managed: cold))
            XCTFail("Port wurde inzwischen anderweitig belegt")
        } catch { XCTAssertTrue(error.localizedDescription.contains("belegt"), error.localizedDescription) }
        XCTAssertTrue(conflict.process.isRunning)
        XCTAssertEqual(try reopened.status(record.id)?.run.id, next.run.id)
        XCTAssertTrue(try String(contentsOf: reopened.log(state.run, stderr: true)).contains("after reopen"))
    }
    func testRefreshedRowRefusesRestartWhenChildPortWasTakenOver() async throws {
        guard ProcessInfo.processInfo.environment["LOKALHOST_TEST_LAUNCHD"] == "1" else {
            throw XCTSkip("Benötigt eine lokale macOS-GUI-Anmeldung mit launchd.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobs = ManagedJobs(directory: directory)
        let script = #"/usr/bin/perl -MIO::Socket::INET -e 'my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>0,Listen=>1) or die; sleep 90'; sleep 90"#
        let service = ServiceRecord(name: "Starter", directory: directory.path, startCommand: script)
        try await jobs.perform(.start, row: ServiceRow(record: service))
        let listeners = try await ListenerInventory.scan().listeners
        let state = try XCTUnwrap(try jobs.status(service.id, listeners: listeners))
        defer { _ = try? jobs.bootout(state.run) }
        let child = try XCTUnwrap(state.listeners.first)
        try await ExternalProcess.stop(child)
        let replacement = try ListenerFixture(port: try XCTUnwrap(child.bindings.first?.port))
        defer { replacement.close() }
        let refreshed = try await ListenerInventory.scan().listeners
        let current = try XCTUnwrap(try jobs.status(service.id, listeners: refreshed))
        XCTAssertTrue(current.isRunning)
        XCTAssertTrue(current.listeners.isEmpty)
        do {
            try await jobs.perform(.restart, row: ServiceRow(record: service, managed: current))
            XCTFail("Portübernahme muss Neustart sperren.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("belegt"), error.localizedDescription) }
        let after = try XCTUnwrap(try jobs.status(service.id))
        defer { _ = try? jobs.bootout(after.run) }
        XCTAssertEqual(after.identity, state.identity)
        XCTAssertTrue(replacement.process.isRunning)
    }

    func testConfirmedStandaloneListenerCanRestartAsManagedService() async throws {
        guard ProcessInfo.processInfo.environment["LOKALHOST_TEST_LAUNCHD"] == "1" else {
            throw XCTSkip("Benötigt eine lokale macOS-GUI-Anmeldung mit launchd.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobs = ManagedJobs(directory: directory)
        let command = #"exec /usr/bin/perl -MIO::Socket::INET -e 'my $s=IO::Socket::INET->new(LocalAddr=>"127.0.0.1",LocalPort=>0,Listen=>1) or die; sleep 90'"#
        let original = ServiceRecord(name: "Terminalersatz", directory: directory.path, startCommand: command)
        try await jobs.perform(.start, row: ServiceRow(record: original))
        let listeners = try await ListenerInventory.scan().listeners
        let oldRun = try XCTUnwrap(try jobs.status(original.id, listeners: listeners))
        defer { try? jobs.bootout(oldRun.run) }
        let external = try XCTUnwrap(oldRun.listeners.first)
        let confirmed = ServiceRecord(name: "Übernommen", directory: directory.path, startCommand: command, lastIdentity: external.identity)
        try await jobs.perform(.restart, row: ServiceRow(record: confirmed, listener: external))
        let fresh = try await ListenerInventory.scan().listeners
        let own = try XCTUnwrap(try jobs.status(confirmed.id, listeners: fresh))
        defer { try? jobs.bootout(own.run) }
        XCTAssertTrue(own.isRunning)
        XCTAssertEqual(own.listeners.count, 1)
        XCTAssertNil(ProcessIdentity.read(external.pid))
        try await jobs.perform(.stop, row: ServiceRow(record: confirmed, managed: own))
    }

}

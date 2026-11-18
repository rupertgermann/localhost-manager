import XCTest
@testable import LokalhostManager

final class ExternalProcessTests: XCTestCase {
    func testWatcherRetainsPortAndStaleStopCannotTerminateReplacement() async throws {
        let first = try ListenerFixture()
        defer { first.close() }
        let inventory = try await ListenerInventory.scan()
        let target = try XCTUnwrap(inventory.listeners.first { $0.pid == first.process.processIdentifier })
        let watcher = Task.detached {
            first.process.waitUntilExit()
            return try ListenerFixture(port: first.port)
        }
        do {
            try await ExternalProcess.stop(target)
            XCTFail("Watcher still owns the port")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("weiterhin belegt"), error.localizedDescription)
        }
        let replacement = try await watcher.value
        defer { replacement.close() }
        do {
            try await ExternalProcess.stop(target)
            XCTFail("A stale stop must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("geändert"), error.localizedDescription)
        }
        XCTAssertTrue(replacement.process.isRunning)
    }
    func testConfirmedProfileCannotRestartWhileExternalSupervisorSurvives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobs = ManagedJobs(directory: directory)
        let fixture = try ListenerFixture()
        defer { fixture.close() }
        let listeners = try await ListenerInventory.scan().listeners
        let listener = try XCTUnwrap(listeners.first { $0.pid == fixture.process.processIdentifier })
        let record = ServiceRecord(name: "Externer Test", directory: directory.path, startCommand: "touch started", lastIdentity: listener.identity)
        do {
            try await jobs.perform(.restart, row: ServiceRow(record: record, listener: listener))
            XCTFail("Der externe Starter läuft noch.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Watcher"), error.localizedDescription) }
        XCTAssertTrue(fixture.process.isRunning)
        XCTAssertNil(try jobs.status(record.id))
    }

}

final class ListenerFixture {
    let process = Process()
    let port: Int

    init(port: Int = 0) throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MIO::Socket::INET", "-e", """
            my $s = IO::Socket::INET->new(LocalAddr=>'127.0.0.1', LocalPort=>$ARGV[0],
                Listen=>1, ReuseAddr=>1) or die $!;
            $|=1; print $s->sockport, "\\n"; sleep 20;
            """, String(port)]
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = output
        try process.run()
        self.port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func close() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

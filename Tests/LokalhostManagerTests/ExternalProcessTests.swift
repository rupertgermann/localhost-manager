import XCTest
@testable import LokalhostManager

final class ExternalProcessTests: XCTestCase {
    func testDockerForwarderCannotBeStoppedOrRestartedThroughNativeActions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try ListenerFixture()
        defer { fixture.close() }
        let listeners = try await ListenerInventory.scan().listeners
        var shown = try XCTUnwrap(listeners.first { $0.pid == fixture.process.processIdentifier })
        shown.executable = "/Applications/Docker.app/Contents/MacOS/com.docker.backend"
        let record = ServiceRecord(name: "Forwarder", directory: directory.path, startCommand: "exit 0", lastIdentity: shown.identity)
        let row = ServiceRow(record: record, listener: shown)
        for action in [ServiceAction.stop, .restart] {
            do {
                try await ManagedJobs(directory: directory).perform(action, row: row)
                XCTFail("Native Docker-Aktion zugelassen")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Docker"), error.localizedDescription) }
        }
        do {
            try await ExternalProcess.stop(shown)
            XCTFail("Forwarder zugelassen")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Docker"), error.localizedDescription) }
        XCTAssertTrue(fixture.process.isRunning)
    }

    func testStopLeavesIPv6ListenerOnSamePortRunning() async throws {
        let first = try ListenerFixture()
        defer { first.close() }
        let other = try ListenerFixture(port: first.port, host: "::1")
        defer { other.close() }
        let listeners = try await ListenerInventory.scan().listeners
        let target = try XCTUnwrap(listeners.first { $0.pid == first.process.processIdentifier })
        let sibling = try XCTUnwrap(listeners.first { $0.pid == other.process.processIdentifier })
        XCTAssertNoThrow(try Predecessor(processes: [], ports: Set(target.bindings)).checkPorts([sibling]))
        try await ExternalProcess.stop(target)
        XCTAssertTrue(other.process.isRunning)
    }

    func testWatcherRetainsPortAndStaleStopCannotTerminateReplacement() async throws {
        let first = try ListenerFixture()
        defer { first.close() }
        let inventory = try await ListenerInventory.scan()
        let target = try XCTUnwrap(inventory.listeners.first { $0.pid == first.process.processIdentifier })
        let watcher = Task.detached {
            try first.waitForExit()
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
    private let exited = DispatchGroup()

    init(port: Int = 0, host: String = "127.0.0.1") throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-MIO::Socket::IP", "-e", """
            my $s = IO::Socket::IP->new(LocalHost=>$ARGV[1], LocalPort=>$ARGV[0], Proto=>'tcp',
                Listen=>1, ReuseAddr=>1) or die $!;
            $|=1; print $s->sockport, "\\n"; sleep 20;
            """, String(port), host]
        process.environment = ["LC_ALL": "C"]
        process.standardOutput = output
        exited.enter()
        process.terminationHandler = { [exited] _ in exited.leave() }
        try process.run()
        self.port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func close() {
        if process.isRunning { process.terminate() }
        XCTAssertNoThrow(try waitForExit())
    }

    func waitForExit() throws {
        guard exited.wait(timeout: .now() + 5) == .success else {
            throw ManagerError("Testprozess hat sich nicht innerhalb von fünf Sekunden beendet.")
        }
    }
}

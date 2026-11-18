import XCTest
@testable import LokalhostManager

final class DockerActionTests: XCTestCase {
    @MainActor
    func testRecreatedReplicaIsRereadWithoutStartingItsReplacement() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = String(repeating: "a", count: 64)
        let replacement = String(repeating: "b", count: 64)
        let state = dir.appendingPathComponent("id")
        try original.write(to: state, atomically: true, encoding: .utf8)
        let script = dir.appendingPathComponent("docker")
        try """
        #!/bin/sh
        cd "$(dirname "$0")" || exit 1
        [ "$1" = --host ] && [ "$2" = unix:///fixture.sock ] || exit 2
        shift 2
        id=$(cat id)
        case "$1 $2" in
          "container ls") echo "$id";;
          "inspect --type")
            for requested do :; done
            [ "$requested" = "$id" ] || { echo 'No such container' >&2; exit 1; }
            echo "{\\"id\\":\\"$id\\",\\"name\\":\\"web-1\\",\\"state\\":\\"exited\\",\\"project\\":\\"shop\\",\\"service\\":\\"web\\",\\"number\\":\\"1\\"}"
            ;;
          *) touch mutation; exit 1;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let store = DockerStore(cli: DockerCLI(socket: "/fixture.sock", executable: script.path))
        await store.refresh()
        let selected = try XCTUnwrap(store.inventory.rows(socket: store.cli.socket, catalog: Catalog(), showStopped: true).first)
        try replacement.write(to: state, atomically: true, encoding: .utf8)
        do {
            try await store.perform(.start, on: selected)
            XCTFail("Die gewählte Instanz wurde ersetzt")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mutation").path))
        }
        XCTAssertEqual(store.inventory.containers.first?.id, replacement)
    }

    func testLogTailKeepsBothStreamsInOrderAndBoundsLongLines() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = String(repeating: "f", count: 64)
        let script = dir.appendingPathComponent("docker")
        try """
        #!/bin/sh
        [ "$*" = "--host unix:///fixture.sock logs --tail 200 \(id)" ] || exit 2
        head -c 90000 /dev/zero | tr '\\000' x
        echo 'stderr marker' >&2
        echo 'stdout marker'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let cli = DockerCLI(socket: "/fixture.sock", executable: script.path)
        let tail = try await cli.logs(id: id)
        XCTAssertEqual(tail.utf8.count, 64 * 1024)
        XCTAssertTrue(tail.hasSuffix("stderr marker\nstdout marker\n"))
    }
}

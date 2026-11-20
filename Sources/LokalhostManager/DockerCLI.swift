import Darwin
import Foundation

struct DockerCLI {
    let socket: String
    let executable: String?

    init(socket: String? = nil, executable: String? = nil) {
        let files = FileManager.default
        let desktop = files.homeDirectoryForCurrentUser.appendingPathComponent(".docker/run/docker.sock").path
        let system = "/var/run/docker.sock"
        self.socket = socket ?? ProcessInfo.processInfo.environment["LOKALHOST_DOCKER_SOCKET"]
            ?? ([desktop, system].first(where: files.fileExists(atPath:)) ?? desktop)
        self.executable = executable ?? [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
            files.homeDirectoryForCurrentUser.appendingPathComponent(".docker/bin/docker").path
        ].first(where: files.isExecutableFile(atPath:))
    }

    struct Output {
        let stdout: Data
        let stderr: Data
    }

    func run(_ arguments: [String], timeout: TimeInterval = 8, logTailBytes: Int? = nil) async throws -> Output {
        guard socket.hasPrefix("/") else { throw ManagerError("Docker requires an absolute path to a local Unix socket.") }
        guard let executable else { throw ManagerError("Docker CLI not found. Install Docker Desktop or the local CLI.") }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--host", "unix://" + socket] + arguments
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = logTailBytes == nil ? stderr : stdout
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            let output = Task.detached {
                let reader = stdout.fileHandleForReading
                guard let limit = logTailBytes else { return reader.readDataToEndOfFile() }
                var tail = Data()
                while let chunk = try reader.read(upToCount: 16 * 1024), !chunk.isEmpty {
                    tail.append(chunk)
                    if tail.count > limit { tail = Data(tail.suffix(limit)) }
                }
                return tail
            }
            let errors = Task.detached { logTailBytes == nil ? stderr.fileHandleForReading.readDataToEndOfFile() : Data() }
            let finished = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: done.wait(timeout: .now() + timeout) == .success) }
            }
            guard finished else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw ManagerError("Docker timed out connecting to the local socket \(socket).")
            }
            let result = try await Output(stdout: output.value, stderr: errors.value)
            guard process.terminationStatus == 0 else {
                let diagnostic = logTailBytes == nil ? result.stderr : result.stdout
                let message = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ManagerError("Docker (\(socket)): " + (message.isEmpty ? "CLI error \(process.terminationStatus)" : message))
            }
            return result
        }.value
    }

    func logs(id: String) async throws -> String {
        guard Self.isFullID(id) else { throw ManagerError("The full container ID is missing.") }
        let output = try await run(["logs", "--tail", "200", id], logTailBytes: 64 * 1024)
        return String(decoding: output.stdout, as: UTF8.self)
    }

    func scan() async throws -> [DockerContainer] {
        let listed = try await run(["container", "ls", "--all", "--quiet", "--no-trunc"])
        let ids = String(decoding: listed.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        var containers: [DockerContainer] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            containers += try await inspect(Array(ids[start..<min(start + 100, ids.count)]))
        }
        return containers
    }

    static func isFullID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    func inspect(_ ids: [String]) async throws -> [DockerContainer] {
        // Select only display fields. A full inspect also contains the container's environment and secrets.
        let format = #"{"id":{{json .Id}},"name":{{json .Name}},"state":{{json .State.Status}},"ports":{{json .NetworkSettings.Ports}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}},"number":{{json (index .Config.Labels "com.docker.compose.container-number")}},"mounts":{{json .Mounts}},"containerDirectory":{{json .Config.WorkingDir}},"workingDirectory":{{json (index .Config.Labels "com.docker.compose.project.working_dir")}},"oneoff":{{json (index .Config.Labels "com.docker.compose.oneoff")}}}"#
        let data = try await run(["inspect", "--type", "container", "--format", format] + ids)
        return try data.stdout.split(separator: 10).map { try JSONDecoder().decode(DockerContainer.self, from: Data($0)) }
    }
}

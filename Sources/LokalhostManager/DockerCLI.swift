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

    func run(_ arguments: [String], timeout: TimeInterval = 8) async throws -> Output {
        guard socket.hasPrefix("/") else { throw ManagerError("Docker benötigt einen absoluten lokalen Unix-Socket.") }
        guard let executable else { throw ManagerError("Docker-CLI fehlt. Docker Desktop oder die lokale CLI installieren.") }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--host", "unix://" + socket] + arguments
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            let output = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
            let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
            let finished = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: done.wait(timeout: .now() + timeout) == .success) }
            }
            guard finished else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw ManagerError("Docker: Zeitüberschreitung am lokalen Socket \(socket).")
            }
            let result = await Output(stdout: output.value, stderr: errors.value)
            guard process.terminationStatus == 0 else {
                let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ManagerError("Docker (\(socket)): " + (message.isEmpty ? "CLI-Fehler \(process.terminationStatus)" : message))
            }
            return result
        }.value
    }

    func scan() async throws -> [DockerContainer] {
        let listed = try await run(["container", "ls", "--all", "--quiet", "--no-trunc"])
        let ids = String(decoding: listed.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace).map(String.init)
        var containers: [DockerContainer] = []
        // Select only display fields. A full inspect also contains the container's environment and secrets.
        let format = #"{"id":{{json .Id}},"name":{{json .Name}},"state":{{json .State.Status}},"ports":{{json .NetworkSettings.Ports}},"project":{{json (index .Config.Labels "com.docker.compose.project")}},"service":{{json (index .Config.Labels "com.docker.compose.service")}},"number":{{json (index .Config.Labels "com.docker.compose.container-number")}},"workingDirectory":{{json (index .Config.Labels "com.docker.compose.project.working_dir")}},"oneoff":{{json (index .Config.Labels "com.docker.compose.oneoff")}}}"#
        for start in stride(from: 0, to: ids.count, by: 100) {
            let batch = ids[start..<min(start + 100, ids.count)]
            let data = try await run(["inspect", "--type", "container", "--format", format] + batch)
            for line in data.stdout.split(separator: 10) {
                containers.append(try JSONDecoder().decode(DockerContainer.self, from: Data(line)))
            }
        }
        return containers
    }
}

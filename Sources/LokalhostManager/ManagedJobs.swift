import Darwin
import Foundation

struct ManagedRun: Codable {
    let serviceID: UUID
    var id = UUID()
    var identity: ProcessIdentity?
    var label: String { "de.lokalhost-manager.\(serviceID.uuidString).\(id.uuidString)" }
}

struct ManagedStatus {
    let run: ManagedRun
    let identity: ProcessIdentity?
    let loaded: Bool
    let exitCode: Int?
    var listeners: [LocalListener] = []
    var observedBindings: Set<HostBinding> = []

    var isRunning: Bool { identity != nil }
    var description: String {
        if isRunning { return "Running" }
        if let exitCode { return exitCode == 0 ? "Exited" : "Error (\(exitCode))" }
        return "Stopped"
    }

    func owns(_ listener: LocalListener) -> Bool {
        guard let root = identity, let child = listener.identity, child.uid == root.uid,
              ProcessIdentity.read(child.pid) == child else { return false }
        var pid = child.pid
        while pid > 1 {
            if pid == root.pid { return ProcessIdentity.read(pid) == root }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == root.uid, info.pbi_ppid != pid else { return false }
            pid = pid_t(info.pbi_ppid)
        }
        return false
    }
}

enum ServiceAction: String {
    case start = "Starting…"
    case stop = "Stopping…"
    case restart = "Restarting…"
}

struct ManagedJobs {
    let directory: URL
    private var domain: String { "gui/\(getuid())" }
    private func folder(_ service: UUID) -> URL {
        directory.appendingPathComponent("runs/\(service.uuidString)", isDirectory: true)
    }
    private func runFolder(_ run: ManagedRun) -> URL {
        folder(run.serviceID).appendingPathComponent(run.id.uuidString, isDirectory: true)
    }
    func log(_ run: ManagedRun, stderr: Bool) -> URL {
        runFolder(run).appendingPathComponent(stderr ? "stderr.log" : "stdout.log")
    }

    // launchctl print can include environment values. Only explicit status fields leave this function.
    private func launchctl(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }

    func status(_ service: UUID, listeners: [LocalListener] = []) throws -> ManagedStatus? {
        let bytes: Data
        do { bytes = try Data(contentsOf: folder(service).appendingPathComponent("current.json")) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let run = try JSONDecoder().decode(ManagedRun.self, from: bytes)
        guard run.serviceID == service else { throw ManagerError("This run belongs to a different service.") }
        var state = try inspect(run)
        let portsFile = runFolder(run).appendingPathComponent("ports.json")
        do { state.observedBindings = try JSONDecoder().decode(Set<HostBinding>.self, from: Data(contentsOf: portsFile)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        if state.isRunning {
            state.listeners = listeners.filter(state.owns)
            let active = Set(state.listeners.flatMap(\.bindings))
            if !active.isSubset(of: state.observedBindings) {
                state.observedBindings.formUnion(active)
                try JSONEncoder().encode(state.observedBindings).write(to: portsFile, options: .atomic)
            }
        }
        return state
    }

    private func inspect(_ run: ManagedRun) throws -> ManagedStatus {
        let (code, output) = try launchctl(["print", "\(domain)/\(run.label)"])
        if code == 113 { return ManagedStatus(run: run, identity: nil, loaded: false, exitCode: nil) }
        guard code == 0 else { throw ManagerError("Could not read launchd status (code \(code)).") }
        let lines = output.components(separatedBy: "\n")
        func field(_ name: String) -> String? {
            let prefix = "\t\(name) = "
            return lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        var root: ProcessIdentity?
        if let pid = field("pid").flatMap(pid_t.init) {
            guard let identity = ProcessIdentity.read(pid), identity.uid == getuid(),
                  run.identity == nil || run.identity == identity else {
                throw ManagerError("Could not verify the identity of the running process.")
            }
            root = identity
        } else if field("state") == "running" {
            throw ManagerError("launchd reports a running job without a verified process identity.")
        }
        return ManagedStatus(run: run, identity: root, loaded: true, exitCode: field("last exit code").flatMap(Int.init))
    }

    func bootout(_ run: ManagedRun) throws {
        let (code, _) = try launchctl(["bootout", "\(domain)/\(run.label)"])
        guard code == 0 || code == 113 else { throw ManagerError("launchd could not remove this job (code \(code)).") }
    }

    private func save(_ run: ManagedRun) throws {
        try JSONEncoder().encode(run).write(to: folder(run.serviceID).appendingPathComponent("current.json"), options: .atomic)
    }

    func perform(_ action: ServiceAction, row: ServiceRow, services: [ServiceRecord] = []) async throws {
        if let error = row.controlError { throw ManagerError(error) }
        guard let service = row.record else {
            guard action == .stop, let listener = row.listener else { throw ManagerError("No confirmed start profile.") }
            try await ExternalProcess.stop(listener)
            return
        }
        let home = folder(service.id)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(home.appendingPathComponent("action.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw ManagerError("Could not acquire the action lock.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ManagerError("Another action is in progress for this service.") }
        let guardFile = home.appendingPathComponent("predecessor.json")
        let listeners = try await ListenerInventory.currentListeners()
        let state = try status(service.id, listeners: listeners)
        let configuration = action == .stop ? nil : try configuration(for: service)
        let predecessor: Predecessor
        if action == .start {
            guard state?.isRunning != true else { throw ManagerError("This service is already running.") }
            predecessor = try previousExecution(service, state, listeners, services: services, file: guardFile)
        } else if let shown = row.managed, shown.isRunning {
            predecessor = try await stopManaged(shown, current: state, listeners: listeners, file: guardFile)
        } else {
            guard state?.isRunning != true, let listener = row.listener, let identity = listener.identity,
                  action == .stop || identity == service.lastIdentity else {
                throw ManagerError("The process identity is unclear. Confirm the current service again.")
            }
            predecessor = try await stopExternal(listener, identity, restarting: action == .restart, file: guardFile)
        }
        try predecessor.checkEnded()
        try predecessor.checkPorts(try await ListenerInventory.currentListeners())
        guard let configuration else { return }
        if let state, state.loaded, !state.isRunning { try bootout(state.run) }
        try launch(service.id, configuration)
    }

    private func previousExecution(_ service: ServiceRecord, _ state: ManagedStatus?, _ listeners: [LocalListener], services: [ServiceRecord], file: URL) throws -> Predecessor {
        var previous: Predecessor
        do { previous = try JSONDecoder().decode(Predecessor.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            previous = Predecessor(processes: [], ports: [])
        }
        if let identity = service.lastIdentity { previous.processes.insert(identity) }
        if let adopted = service.externalSupervisor, ProcessIdentity.read(adopted.pid) == adopted {
            throw ManagerError("The parent process or watcher is still running.")
        }
        previous.ports.formUnion(service.externalPorts ?? [])
        previous.ports.formUnion(state?.observedBindings ?? [])
        if let executable = service.executable {
            var candidates = listeners.filter {
                ($0.directory == service.directory && ($0.executable == nil || $0.executable == executable)) ||
                ($0.directory == nil && $0.executable == executable)
            }
            for other in services where other.id != service.id && !candidates.isEmpty {
                let run = try status(other.id)
                candidates.removeAll { listener in
                    if run?.owns(listener) == true { return true }
                    guard let identity = listener.identity, identity == other.lastIdentity else { return false }
                    return ProcessIdentity.read(identity.pid) == identity
                }
            }
            if !candidates.isEmpty {
                throw ManagerError("A matching external service is running in this project. Confirm its identity first.")
            }
        }
        return previous
    }

    private func stopManaged(_ shown: ManagedStatus, current state: ManagedStatus?, listeners: [LocalListener], file: URL) async throws -> Predecessor {
        guard let state, let root = state.identity, root == shown.identity, shown.run.id == state.run.id else {
            throw ManagerError("The displayed run has changed.")
        }
        if state.listeners.contains(where: { LocalListener.isDockerForwarder($0.executable) }) {
            throw ManagerError(LocalListener.dockerControlError)
        }
        for listener in shown.listeners {
            guard state.listeners.contains(where: { $0.identity == listener.identity && Set($0.bindings) == Set(listener.bindings) }) else {
                throw ManagerError("The listener or its bindings have changed.")
            }
        }
        let owned = Set(state.listeners.compactMap(\.identity))
        var previous = Predecessor(processes: try Predecessor.tree(root).union(owned), ports: shown.observedBindings.union(state.observedBindings))
        if getpgid(root.pid) == root.pid { previous.processGroup = root.pid }
        try previous.checkPorts(listeners, excluding: owned)
        try JSONEncoder().encode(previous).write(to: file, options: .atomic)
        try bootout(state.run)
        let deadline = ContinuousClock.now + .seconds(8)
        while previous.hasLiveProcesses, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !(try inspect(state.run)).loaded else { throw ManagerError("launchd has not yet removed the previous run.") }
        return previous
    }

    private func stopExternal(_ listener: LocalListener, _ identity: ProcessIdentity, restarting: Bool, file: URL) async throws -> Predecessor {
        var previous = Predecessor(processes: try Predecessor.tree(identity), ports: Set(listener.bindings),
                                   supervisor: try Predecessor.supervisor(of: identity))
        try JSONEncoder().encode(previous).write(to: file, options: .atomic)
        if restarting { try previous.checkSupervisor() }
        try await ExternalProcess.stop(listener)
        if !restarting { previous.supervisor = nil }
        return previous
    }

    private func configuration(for service: ServiceRecord) throws -> [String: Any] {
        guard let path = service.directory, path.hasPrefix("/"),
              let command = service.startCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManagerError("Confirm the working directory and start command.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ManagerError("Working directory not found: \(path)")
        }
        var env = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        if let envFile = service.envFile, !envFile.isEmpty {
            let url = URL(fileURLWithPath: envFile, relativeTo: URL(fileURLWithPath: path, isDirectory: true))
            let data: String
            do { data = try String(contentsOf: url, encoding: .utf8) }
            catch { throw ManagerError("Environment file missing, unreadable or not UTF-8: \(url.path)") }
            env.merge(try ManagedEnvironment.parse(data)) { _, custom in custom }
        }

        return ["ProgramArguments": ["/bin/sh", "-c", command], "WorkingDirectory": path,
                "EnvironmentVariables": env, "RunAtLoad": false, "KeepAlive": false]
    }

    private func launch(_ service: UUID, _ configuration: [String: Any]) throws {
        let fm = FileManager.default
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        var run = ManagedRun(serviceID: service)
        let jobFolder = runFolder(run)
        try fm.createDirectory(at: jobFolder, withIntermediateDirectories: true, attributes: permissions)
        let plist = jobFolder.appendingPathComponent("job.plist")
        var job = configuration
        job["Label"] = run.label
        job["StandardOutPath"] = log(run, stderr: false).path
        job["StandardErrorPath"] = log(run, stderr: true).path
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist, options: .atomic)
        defer { try? fm.removeItem(at: plist) }
        try save(run) // Write the label before launchd can start a process, including on app termination.
        let (bootstrap, _) = try launchctl(["bootstrap", domain, plist.path])
        guard bootstrap == 0 else { throw ManagerError("launchd could not load the user job (code \(bootstrap)).") }
        let (kickstart, output) = try launchctl(["kickstart", "-p", "\(domain)/\(run.label)"])
        guard kickstart == 0 else { throw ManagerError("launchd could not start the service (code \(kickstart)).") }
        if let pid = pid_t(output.trimmingCharacters(in: .whitespacesAndNewlines)),
           let identity = ProcessIdentity.read(pid), identity.uid == getuid() {
            run.identity = identity
            try save(run)
        }
        Thread.sleep(forTimeInterval: 0.35)
        let state = try inspect(run)
        if let code = state.exitCode, !state.isRunning, code != 0 {
            let reason = code == 127 ? "Program not found" : code == 126 ? "Program is not executable" : "Command exited early"
            throw ManagerError("Start failed: \(reason) (exit code \(code)).")
        }
    }
}

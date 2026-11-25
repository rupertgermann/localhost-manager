import Darwin
import Foundation

// Foundation may abbreviate /private/tmp to /tmp again when standardizing a file URL.
func physicalDirectory(_ path: String) -> String {
    LocalVolumes().resolveLocalPath(path) ?? path
}

struct Project: Identifiable, Codable {
    var id = UUID()
    var name: String
    var directory: String
}

struct ServiceRecord: Identifiable, Codable {
    var id = UUID()
    var name: String
    var projectID: UUID?
    var directory: String?
    var startCommand: String?
    var envFile: String?
    var executable: String?
    var lastIdentity: ProcessIdentity?
    var externalPorts: Set<HostBinding>?
    var externalSupervisor: ProcessIdentity?
    var webTargets: [URL] = []
    var logPath: String?
}

struct ServiceRow: Identifiable {
    var record: ServiceRecord?
    var listener: LocalListener?
    var projectID: UUID?

    var managed: ManagedStatus?
    var workingDirectories: [String] {
        if let managed, managed.isRunning {
            let paths = Set(managed.listeners.compactMap(\.directory))
            if !paths.isEmpty { return paths.sorted() }
        }
        if let listener { return listener.directory.map { [$0] } ?? [] }
        return record?.directory.map { [$0] } ?? []
    }

    var bindings: [HostBinding] {
        if let managed, managed.isRunning { return managed.listeners.flatMap(\.bindings).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
        return listener?.bindings ?? []
    }

    var controlError: String? {
        if LocalListener.isDockerForwarder(record?.executable) ||
            managed?.listeners.contains(where: { LocalListener.isDockerForwarder($0.executable) }) == true {
            return LocalListener.dockerControlError
        }
        return listener?.controlError
    }

    var id: String {
        if let record { return record.id.uuidString }
        guard let listener else { return "" }
        return "pid-\(listener.pid)-\(listener.identity?.seconds ?? 0)-\(listener.identity?.microseconds ?? 0)"
    }
    var name: String { record?.name ?? listener?.name ?? "Unknown" }
    var editableRecord: ServiceRecord {
        record ?? ServiceRecord(name: name, directory: listener?.directory, executable: listener?.executable, lastIdentity: listener?.identity)
    }
}

enum HiddenServiceRule: Codable, Hashable {
    case name(String)
    case port(Int)

    func matches(name: String, ports: [Int]) -> Bool {
        switch self {
        case .name(let hiddenName): name.caseInsensitiveCompare(hiddenName) == .orderedSame
        case .port(let port): ports.contains(port)
        }
    }
}

struct Catalog: Codable {
    var projects: [Project] = []
    var services: [ServiceRecord] = []

    var docker: [DockerRecord]?
    var hiddenServices: [HiddenServiceRule]?

    func hides(name: String, ports: [Int]) -> Bool {
        hiddenServices?.contains { $0.matches(name: name, ports: ports) } ?? false
    }

    func write(to file: URL) throws {
        let files = FileManager.default
        let directory = file.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true)
        defer { try? files.removeItem(at: staging) }
        let replacement = staging.appendingPathComponent(file.lastPathComponent)
        let bytes = try JSONEncoder().encode(self)
        guard files.createFile(atPath: replacement.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            throw ManagerError("Could not write the service catalog.")
        }
        guard rename(replacement.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func read(from file: URL) throws -> Self {
        do {
            var catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file))
            for index in catalog.projects.indices {
                catalog.projects[index].directory = physicalDirectory(catalog.projects[index].directory)
            }
            for index in catalog.services.indices {
                catalog.services[index].directory = catalog.services[index].directory.map(physicalDirectory)
            }
            catalog.docker = catalog.docker?.map { record in
                var entry = record
                entry.directory = entry.directory.map(physicalDirectory)
                if entry.instance == "Einzelcontainer" {
                    entry.instance = "Standalone container"
                } else {
                    entry.instance = entry.instance.replacingOccurrences(of: " · Instanz ", with: " · Instance ")
                        .replacingOccurrences(of: " · Einmallauf", with: " · One-off")
                }
                return entry
            }
            return catalog
        }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Catalog() }
    }

    func project(for directory: String?) -> UUID? {
        guard let directory else { return nil }
        let candidates = projects.filter {
            directory == $0.directory || directory.hasPrefix($0.directory == "/" ? "/" : $0.directory + "/")
        }
        let closest = candidates.filter { $0.directory.count == candidates.map(\.directory.count).max() }
        return closest.count == 1 ? closest[0].id : nil
    }

    func rows(for listeners: [LocalListener], managed: [UUID: ManagedStatus] = [:]) -> [ServiceRow] {
        var used: Set<UUID> = []
        var claimed: Set<ProcessIdentity> = []
        var rows: [ServiceRow] = []
        for record in services {
            guard let state = managed[record.id], state.isRunning else { continue }
            used.insert(record.id)
            claimed.formUnion(state.listeners.compactMap(\.identity))
            rows.append(ServiceRow(record: record, listener: state.listeners.first, projectID: record.projectID ?? project(for: record.directory), managed: state))
        }
        let external = listeners.filter { $0.identity.map { !claimed.contains($0) } ?? true }
        for listener in external {
            var record = services.first { !used.contains($0.id) && $0.lastIdentity != nil && $0.lastIdentity == listener.identity }
            if record == nil, let directory = listener.directory, let executable = listener.executable {
                let candidates = services.filter { $0.directory == directory && $0.executable == executable }
                let siblings = listeners.filter { $0.directory == directory && $0.executable == executable }
                if candidates.count == 1 && siblings.count == 1 && !used.contains(candidates[0].id) { record = candidates[0] }
            }
            if let record { used.insert(record.id) }
            rows.append(ServiceRow(record: record, listener: listener, projectID: record?.projectID ?? project(for: listener.directory), managed: record.flatMap { managed[$0.id] }))
        }
        for record in services where !used.contains(record.id) {
            rows.append(ServiceRow(record: record, projectID: record.projectID ?? project(for: record.directory), managed: managed[record.id]))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

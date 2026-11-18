import Foundation

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
    var webTargets: [URL] = []
}

struct ServiceRow: Identifiable {
    var record: ServiceRecord?
    var listener: LocalListener?
    var projectID: UUID?

    var managed: ManagedStatus?
    var bindings: [HostBinding] {
        if let managed, managed.isRunning { return managed.listeners.flatMap(\.bindings).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
        return listener?.bindings ?? []
    }

    var id: String {
        if let record { return record.id.uuidString }
        guard let listener else { return "" }
        return "pid-\(listener.pid)-\(listener.identity?.seconds ?? 0)-\(listener.identity?.microseconds ?? 0)"
    }
    var name: String { record?.name ?? listener?.name ?? "Unbekannt" }
    var editableRecord: ServiceRecord {
        record ?? ServiceRecord(name: name, directory: listener?.directory, executable: listener?.executable, lastIdentity: listener?.identity)
    }
}

struct Catalog: Codable {
    var projects: [Project] = []
    var services: [ServiceRecord] = []

    private func project(for directory: String?) -> UUID? {
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

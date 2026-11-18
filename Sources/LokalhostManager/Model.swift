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
    var executable: String?
    var lastIdentity: ProcessIdentity?
    var webTargets: [URL] = []
    var logPath: String?
}

struct ServiceRow: Identifiable {
    var record: ServiceRecord?
    var listener: LocalListener?
    var projectID: UUID?

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

    func rows(for listeners: [LocalListener]) -> [ServiceRow] {
        var used: Set<UUID> = []
        var rows = listeners.map { listener -> ServiceRow in
            var record = services.first { $0.lastIdentity != nil && $0.lastIdentity == listener.identity }
            if record == nil, let directory = listener.directory, let executable = listener.executable {
                let candidates = services.filter { $0.directory == directory && $0.executable == executable }
                let siblings = listeners.filter { $0.directory == directory && $0.executable == executable }
                if candidates.count == 1 && siblings.count == 1 { record = candidates[0] }
            }
            if let record { used.insert(record.id) }
            return ServiceRow(record: record, listener: listener, projectID: record?.projectID ?? project(for: listener.directory))
        }
        for record in services where !used.contains(record.id) {
            rows.append(ServiceRow(record: record, projectID: record.projectID ?? project(for: record.directory)))
        }
        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

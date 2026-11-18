import Foundation
import SwiftUI

enum DockerKey: Hashable, Codable {
    case container(String)
    case compose(project: String, service: String, number: String)
}

extension DockerContainer {
    var key: DockerKey {
        if !oneoff, let project, let service, let number { return .compose(project: project, service: service, number: number) }
        return .container(id)
    }
}

struct DockerRecord: Codable {
    let socket: String
    let key: DockerKey
    var name: String
    var instance: String
    var composeProject: String?
    var directory: String?
    var projectID: UUID?
    var webTargets: [URL] = []
}

struct DockerRow: Identifiable {
    var editableRecord: DockerRecord
    var container: DockerContainer?
    let available: Bool
    let projectID: UUID?

    var id: DockerKey { editableRecord.key }
    var current: DockerContainer? { available ? container : nil }
    var status: String {
        guard available else { return "Unbekannt" }
        switch container?.state {
        case nil: return "Container fehlt"
        case "running": return "Läuft"
        case "paused": return "Pausiert"
        case "restarting": return "Startet neu"
        case "exited", "created": return "Gestoppt"
        case "dead": return "Defekt"
        case "removing": return "Wird entfernt"
        default: return container?.state ?? "Unbekannt"
        }
    }

    var webTargets: [URL] {
        guard let current, current.state == "running" else { return [] }
        let bindings = current.ports.filter { $0.destination.hasSuffix("/tcp") }.map(\.host)
        return Set(current.webTargets + editableRecord.webTargets.filter { WebTarget.accepts($0, on: bindings) }).sorted { $0.absoluteString < $1.absoluteString }
    }
}

struct DockerInventory {
    var containers: [DockerContainer] = []
    var available = false
    var error: String?

    func nativeListeners(_ listeners: [LocalListener]) -> [LocalListener] {
        guard available else { return listeners }
        var owners: [HostBinding: Int] = [:]
        for port in containers.flatMap(\.ports) where port.destination.hasSuffix("/tcp") {
            owners[port.host, default: 0] += 1
        }
        return listeners.compactMap { listener in
            guard listener.executable == "/Applications/Docker.app/Contents/MacOS/com.docker.backend" else { return listener }
            var filtered = listener
            filtered.bindings.removeAll { binding in
                var host = binding
                host.host = host.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if host.host == "*" { host.host = host.family == "IPv6" ? "::" : "0.0.0.0" }
                return owners[host] == 1
            }
            return filtered.bindings.isEmpty ? nil : filtered
        }
    }

    func rows(socket: String, catalog: Catalog, showStopped: Bool) -> [DockerRow] {
        let stored = (catalog.docker ?? []).filter { $0.socket == socket }
        let instances = Dictionary(grouping: containers, by: \.key)
        var seen = Set<DockerKey>()
        var rows: [DockerRow] = []
        for container in containers {
            // Compose can temporarily present two containers for a replica during recreation.
            let key = instances[container.key]?.count == 1 ? container.key : .container(container.id)
            let saved = stored.first { $0.key == key }
            guard showStopped || saved != nil || ["running", "restarting", "paused"].contains(container.state) else { continue }
            let record = DockerRecord(socket: socket, key: key, name: container.name, instance: container.instanceDescription,
                                      composeProject: container.project, directory: container.workingDirectory,
                                      projectID: saved?.projectID, webTargets: saved?.webTargets ?? [])
            seen.insert(key)
            rows.append(DockerRow(editableRecord: record, container: container, available: available,
                                  projectID: record.projectID ?? catalog.project(for: record.directory)))
        }
        for record in stored where !seen.contains(record.key) {
            rows.append(DockerRow(editableRecord: record, available: available,
                                  projectID: record.projectID ?? catalog.project(for: record.directory)))
        }
        return rows.sorted { $0.editableRecord.name.localizedStandardCompare($1.editableRecord.name) == .orderedAscending }
    }
}

@MainActor
final class DockerStore: ObservableObject {
    let cli = DockerCLI()
    @Published private(set) var inventory = DockerInventory()
    private var refreshing = false

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do { inventory = DockerInventory(containers: try await cli.scan(), available: true) }
        catch { inventory = DockerInventory(containers: inventory.containers, available: false, error: error.localizedDescription) }
    }
}

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
        guard available else { return "Unknown" }
        switch container?.state {
        case nil: return "Container missing"
        case "running": return "Running"
        case "paused": return "Paused"
        case "restarting": return "Restarting"
        case "exited", "created": return "Stopped"
        case "dead": return "Failed"
        case "removing": return "Removing"
        default: return container?.state ?? "Unknown"
        }
    }

    var webTargets: [URL] {
        guard let current, current.state == "running" else { return [] }
        let bindings = current.ports.filter { $0.destination.hasSuffix("/tcp") }.map(\.host)
        return editableRecord.webTargets.filter { WebTarget.accepts($0, on: bindings) }.sorted { $0.absoluteString < $1.absoluteString }
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
            guard LocalListener.isDockerForwarder(listener.executable) else { return listener }
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
            let exact = DockerKey.container(container.id)
            let unique = instances[container.key]?.count == 1
            let useExact = stored.contains { $0.key == exact } || !unique
            let key = useExact ? exact : container.key
            let saved = stored.first { $0.key == key }
            guard showStopped || saved != nil || DockerContainer.isActive(container.state) else { continue }
            let record = DockerRecord(socket: socket, key: key, name: container.name, instance: container.instanceDescription,
                                      composeProject: container.project, directory: container.workingDirectory,
                                      projectID: saved?.projectID, webTargets: saved?.webTargets ?? [])
            seen.insert(key)
            if unique { seen.insert(container.key) }
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

enum DockerAction: String, CaseIterable {
    case start, stop, restart

    var title: String {
        switch self {
        case .start: return "Start"
        case .stop: return "Stop"
        case .restart: return "Restart"
        }
    }

    func accepts(_ state: String) -> Bool {
        switch self {
        case .start: return ["created", "exited"].contains(state)
        case .stop, .restart: return DockerContainer.isActive(state)
        }
    }
}

@MainActor
final class DockerStore: ObservableObject {
    let cli: DockerCLI
    @Published private(set) var inventory = DockerInventory()
    @Published private(set) var busy = Set<String>()
    private var refreshing = false
    private var generation = 0

    init(cli: DockerCLI = DockerCLI()) { self.cli = cli }

    func refresh(afterAction: Bool = false) async {
        guard afterAction || !refreshing else { return }
        generation += 1
        let request = generation
        refreshing = true
        defer { if request == generation { refreshing = false } }
        do {
            let containers = try await cli.scan()
            if request == generation { inventory = DockerInventory(containers: containers, available: true) }
        } catch {
            if request == generation {
                inventory = DockerInventory(containers: inventory.containers, available: false, error: error.localizedDescription)
            }
        }
    }

    func perform(_ action: DockerAction, on row: DockerRow) async throws {
        guard inventory.available, row.editableRecord.socket == cli.socket, let target = row.current,
              inventory.containers.contains(where: { $0.id == target.id }) else {
            throw ManagerError("Container unavailable. Refresh the list and try again.")
        }
        guard busy.insert(target.id).inserted else { throw ManagerError("Another action is in progress for this container.") }
        defer { busy.remove(target.id) }
        do {
            guard DockerCLI.isFullID(target.id),
                  let current = try await cli.inspect([target.id]).first,
                  inventory.available, current.id == target.id, action.accepts(current.state) else {
                throw ManagerError("The selected container or its state has changed.")
            }
            _ = try await cli.run(["container", action.rawValue, target.id], timeout: 60)
        } catch {
            await refresh(afterAction: true)
            throw error
        }
        await refresh(afterAction: true)
    }
}

import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var catalog = Catalog()
    @Published private(set) var inventory = ListenerInventory(listeners: [], warning: nil, visibility: .unavailable)
    @Published private(set) var refreshing = false
    @Published private(set) var ready = false
    @Published var message: String?
    let dataDirectory: URL
    private var saving = false
    @Published private(set) var managed: [UUID: ManagedStatus] = [:]
    @Published private(set) var managedErrors: [UUID: String] = [:]
    @Published private(set) var actions: [String: ServiceAction] = [:]
    private var refreshRequested = false

    init(dataDirectory: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        if let dataDirectory { self.dataDirectory = dataDirectory }
        else if let path = environment["LOKALHOST_DATA_DIR"], !path.isEmpty {
            self.dataDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            self.dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lokalhost Manager", isDirectory: true)
        }
    }

    func load() async {
        let file = dataDirectory.appendingPathComponent("catalog.json")
        do {
            catalog = try await Task.detached {
                try Catalog.read(from: file)
            }.value
            ready = true
        } catch {
            message = "Could not load saved services. \(error.localizedDescription)"
        }
        await refresh()
    }

    func refresh(scan: () async throws -> ListenerInventory = ListenerInventory.scan) async {
        guard !refreshing else { refreshRequested = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshRequested = false
            let snapshot: ListenerInventory
            do { snapshot = try await scan() }
            catch {
                inventory = ListenerInventory(listeners: inventory.listeners, warning: error.localizedDescription, visibility: .unavailable)
                continue
            }
            let jobs = ManagedJobs(directory: dataDirectory), services = catalog.services, listeners = snapshot.listeners
            (managed, managedErrors) = await Task.detached {
                var states: [UUID: ManagedStatus] = [:], errors: [UUID: String] = [:]
                for service in services {
                    do { states[service.id] = try jobs.status(service.id, listeners: listeners) }
                    catch { errors[service.id] = error.localizedDescription }
                }
                return (states, errors)
            }.value
            inventory = snapshot
        } while refreshRequested
    }

    func perform(_ action: ServiceAction, row: ServiceRow) async {
        guard ready, actions[row.id] == nil else { return }
        do { try inventory.requireCurrent() }
        catch { message = error.localizedDescription; return }
        if let error = row.controlError { message = error; return }
        actions[row.id] = action
        defer { actions[row.id] = nil }
        message = nil
        let jobs = ManagedJobs(directory: dataDirectory)
        do { try await jobs.perform(action, row: row, services: catalog.services) }
        catch { message = "\(row.name): \(error.localizedDescription)" }
        while refreshing {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        await refresh()
    }

    func save(_ next: Catalog) async throws {
        guard ready, !saving else { throw ManagerError("The project file cannot be written right now.") }
        saving = true
        defer { saving = false }
        let directory = dataDirectory
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let bytes = try JSONEncoder().encode(next)
            try bytes.write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
        }.value
        catalog = next
    }
}

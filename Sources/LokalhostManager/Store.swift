import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var catalog = Catalog()
    @Published private(set) var inventory = ListenerInventory(listeners: [], warning: nil)
    @Published private(set) var refreshing = false
    @Published private(set) var ready = false
    @Published private(set) var stoppingExternal: String?
    @Published var message: String?
    let dataDirectory: URL
    private var saving = false
    @Published private(set) var managed: [UUID: ManagedStatus] = [:]
    @Published private(set) var managedErrors: [UUID: String] = [:]
    @Published private(set) var starting: Set<UUID> = []
    private var refreshRequested = false

    init() {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["LOKALHOST_DATA_DIR"], !path.isEmpty {
            dataDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
            message = "Gespeicherte Dienste konnten nicht geladen werden. \(error.localizedDescription)"
        }
        await refresh()
    }

    func refresh() async {
        guard !refreshing else { refreshRequested = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshRequested = false
            let snapshot: ListenerInventory
            do { snapshot = try await ListenerInventory.scan() }
            catch { snapshot = ListenerInventory(listeners: [], warning: error.localizedDescription) }
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

    func start(_ service: ServiceRecord) async {
        guard ready, starting.insert(service.id).inserted else { return }
        defer { starting.remove(service.id) }
        message = nil
        let jobs = ManagedJobs(directory: dataDirectory)
        do { try await Task.detached { try jobs.start(service) }.value }
        catch { message = error.localizedDescription }
        await refresh()
    }

    func stopExternal(_ listener: LocalListener, row: ServiceRow) async {
        guard stoppingExternal == nil else { return }
        stoppingExternal = row.id
        defer { stoppingExternal = nil }
        do {
            try await ExternalProcess.stop(listener)
            message = "\(row.name) wurde gestoppt."
        } catch { message = "\(row.name): \(error.localizedDescription)" }
        while refreshing {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        await refresh()
    }

    func save(_ next: Catalog) async throws {
        guard ready, !saving else { throw ManagerError("Die Projektdatei ist zurzeit nicht beschreibbar.") }
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

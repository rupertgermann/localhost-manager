import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var catalog = Catalog()
    @Published private(set) var inventory = ListenerInventory(listeners: [], warning: nil)
    @Published private(set) var refreshing = false
    @Published private(set) var ready = false
    @Published var message: String?
    let dataDirectory: URL
    private var saving = false

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
                do { return try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: file)) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { return Catalog() }
            }.value
            ready = true
        } catch {
            message = "Gespeicherte Dienste konnten nicht geladen werden. \(error.localizedDescription)"
        }
        await refresh()
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do { inventory = try await ListenerInventory.scan() }
        catch { inventory = ListenerInventory(listeners: [], warning: error.localizedDescription) }
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

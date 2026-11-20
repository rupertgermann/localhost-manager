import AppKit
import SwiftUI

struct Dashboard: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("darkMode") private var darkMode: Bool?
    @StateObject private var docker = DockerStore()
    @State private var showStopped = false
    @State private var filter = ""
    @State private var selectedCategory: ProcessCategory?
    @State private var systemServices = false
    @State private var showingSettings = false
    @State private var creatingProject = false
    @State private var editing: ServiceRow?
    @State private var dockerLogs: DockerContainer?

    var body: some View {
        let isDark = darkMode ?? (colorScheme == .dark)
        let appearanceAction = isDark ? "Switch to Light Mode" : "Switch to Dark Mode"
        let listeners = docker.inventory.nativeListeners(store.inventory.listeners)
        let detectedRows = store.catalog.rows(for: listeners, managed: store.managed)
        let localRows = detectedRows.filter { row in
            (systemServices || row.listener?.isSystem != true) &&
                !store.catalog.hides(name: row.name, ports: row.bindings.map(\.port))
        }
        let dockerRows = docker.inventory.rows(socket: docker.cli.socket, catalog: store.catalog, showStopped: showStopped)
            .filter { !store.catalog.hides(name: $0.editableRecord.name, ports: $0.container?.ports.map(\.host.port) ?? []) }
        let categories = Set(localRows.map(\.category)).union(dockerRows.isEmpty ? [] : [.docker])
        let rows = localRows.filter(matches)
        let containers = dockerRows.filter { row in
            guard selectedCategory == nil || selectedCategory == .docker else { return false }
            let text = [row.editableRecord.name, row.editableRecord.instance, row.container?.id ?? "", row.container?.containerDirectory ?? "", row.editableRecord.directory ?? ""] + (row.container?.ports.map(\.description) ?? [])
            return filter.isEmpty || text.contains { $0.localizedCaseInsensitiveContains(filter) }
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "server.rack").font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.teal).frame(width: 48, height: 48)
                    .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local Services").font(.largeTitle.bold())
                    let serviceCount = rows.count + containers.count
                    let projectCount = store.catalog.projects.count
                    Text("\(serviceCount) \(serviceCount == 1 ? "service" : "services") · \(projectCount) \(projectCount == 1 ? "project" : "projects")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showingSettings = true } label: {
                    Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
                }
                .accessibilityLabel("Settings")
                .help("Settings")
                .keyboardShortcut(",", modifiers: .command)
                Button {
                    darkMode = !isDark
                } label: {
                    Label(appearanceAction, systemImage: isDark ? "sun.max" : "moon")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel(appearanceAction)
                .help(appearanceAction)
                Button { creatingProject = true } label: { Label("Add Project", systemImage: "folder.badge.plus") }
                    .disabled(!store.ready)
            }.padding(20)
            Divider()
            HStack {
                TextField("Search services", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                Toggle("Stopped containers", isOn: $showStopped).toggleStyle(.checkbox)
                Toggle("System services", isOn: $systemServices).toggleStyle(.checkbox)
                Button { Task { await store.refresh() }; Task { await docker.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.refreshing).keyboardShortcut("r")
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    categoryButton(nil)
                    ForEach(ProcessCategory.allCases.filter { categories.contains($0) || $0 == selectedCategory }, id: \.self) {
                        categoryButton($0)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 9)
            }.accessibilityLabel("Filter by process category")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(store.catalog.projects) { project in
                        let services = rows.filter { $0.projectID == project.id }
                        let assigned = containers.filter { $0.projectID == project.id }
                        if !services.isEmpty || !assigned.isEmpty || (filter.isEmpty && selectedCategory == nil) {
                            group(project.name, rows: services, containers: assigned, project: project)
                        }
                    }
                    let unassigned = rows.filter { $0.projectID == nil }
                    let automatic = containers.filter { $0.projectID == nil }
                    let composeProjects = Set(automatic.compactMap { $0.editableRecord.composeProject }).sorted()
                    ForEach(composeProjects, id: \.self) { name in
                        group(name, rows: [], containers: automatic.filter { $0.editableRecord.composeProject == name })
                    }
                    let standalone = automatic.filter { $0.editableRecord.composeProject == nil }
                    if !unassigned.isEmpty || !standalone.isEmpty { group("Unassigned", rows: unassigned, containers: standalone) }
                    if rows.isEmpty && containers.isEmpty {
                        Text(store.refreshing ? "Looking for listeners…" : "No matching services.")
                            .foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            if let error = docker.inventory.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled).padding(10)
            } else if docker.inventory.available && docker.inventory.containers.isEmpty {
                Text("Docker: no containers").font(.caption).foregroundStyle(.secondary).padding(10)
            }
            if let message = store.message ?? store.inventory.warning {
                Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    .foregroundStyle(.primary).font(.callout).padding(10)
            } else {
                Label("Local TCP listeners on this Mac", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary).font(.caption).padding(10)
            }
        }
        .frame(minWidth: 780, minHeight: 440)
        .preferredColorScheme(darkMode.map { $0 ? .dark : .light })
        .sheet(isPresented: $showingSettings) {
            HiddenServicesSettings(rows: detectedRows, containers: docker.inventory.rows(
                socket: docker.cli.socket, catalog: store.catalog, showStopped: true
            ))
        }
        .sheet(isPresented: $creatingProject) { ProjectEditor() }
        .sheet(item: $dockerLogs) { DockerLogPanel(docker: docker, container: $0) }
        .sheet(item: $editing) { ServiceEditor(row: $0) }
        .task {
            while !Task.isCancelled {
                await docker.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
        .task {
            await store.load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await store.refresh()
            }
        }
    }

    private func categoryButton(_ category: ProcessCategory?) -> some View {
        let selected = selectedCategory == category
        let color = category?.color ?? .accentColor
        return Button {
            selectedCategory = category
        } label: {
            HStack(spacing: 5) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(color)
                } else if category != nil {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(category?.rawValue ?? "All")
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(selected ? 0.22 : 0.09), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? color.opacity(0.7) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func matches(_ row: ServiceRow) -> Bool {
        guard selectedCategory == nil || row.category == selectedCategory else { return false }
        if filter.isEmpty { return true }
        let text = [row.name, row.listener?.pid.description ?? ""] + row.workingDirectories + row.bindings.map(\.description)
        return text.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func group(_ title: String, rows: [ServiceRow], containers: [DockerRow], project: Project? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: "folder").font(.headline)
                Spacer()
                Text("\(rows.count + containers.count)").foregroundStyle(.secondary).monospacedDigit()
                if let project {
                    Button("Add Service") {
                        let record = ServiceRecord(name: "", projectID: project.id, directory: project.directory)
                        editing = ServiceRow(record: record, projectID: project.id)
                    }.disabled(!store.ready)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if rows.isEmpty && containers.isEmpty { Text("No services").foregroundStyle(.secondary).padding(12) }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    service(row)
                    hideMenu(name: row.name, ports: row.bindings.map(\.port))
                }.padding(.horizontal, 12).padding(.vertical, 9)
                    .background { row.category.rowBackground }
                if row.id != rows.last?.id || !containers.isEmpty { Divider() }
            }
            ForEach(containers) { row in
                HStack(spacing: 8) {
                    DockerServiceView(docker: docker, row: row, showLogs: { dockerLogs = $0 })
                    hideMenu(name: row.editableRecord.name, ports: row.container?.ports.map(\.host.port) ?? [])
                }.padding(.horizontal, 12).padding(.vertical, 9)
                    .background { ProcessCategory.docker.rowBackground }
                if row.id != containers.last?.id { Divider() }
            }
        }.background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
    }

    private func hideMenu(name: String, ports: [Int]) -> some View {
        Menu {
            Button("Hide all named “\(name)”") {
                Task { await store.setHidden(.name(name), hidden: true) }
            }
            ForEach(Set(ports).sorted(), id: \.self) { port in
                Button("Hide port \(String(port))") {
                    Task { await store.setHidden(.port(port), hidden: true) }
                }
            }
        } label: {
            Label("Hide service", systemImage: "eye.slash").labelStyle(.iconOnly)
        }
        .accessibilityLabel("Hide \(name)")
        .help("Hide by name or port")
        .fixedSize()
        .disabled(!store.ready || store.saving)
    }

    private func service(_ row: ServiceRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.semibold))
                HStack {
                    row.category.badge
                    if let listener = row.listener {
                        Text("PID \(String(listener.pid))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if row.workingDirectories.isEmpty {
                    WorkingDirectoryLine(hostPath: nil)
                } else {
                    ForEach(row.workingDirectories, id: \.self) { WorkingDirectoryLine(hostPath: $0) }
                }
            }.frame(minWidth: 95, maxWidth: .infinity, alignment: .leading)
            let action = store.actions[row.id]
            let error = row.record.flatMap { store.managedErrors[$0.id] }
            let running = row.listener != nil || row.managed?.isRunning == true
            let uncertain = store.inventory.visibility == .unavailable || (store.inventory.visibility == .partial && !running)
            let status = action?.rawValue ?? (error != nil || uncertain ? "Unknown" : running ? "Running" : row.managed?.description ?? "Stopped")
            Label(status, systemImage: running && !uncertain ? "circle.fill" : "stop.circle")
                .font(.callout).foregroundStyle(running && !uncertain ? Color.teal : Color.secondary).frame(width: 92, alignment: .leading).help(error ?? status)
            VStack(alignment: .leading, spacing: 2) {
                if !row.bindings.isEmpty {
                    ForEach(row.bindings, id: \.self) { binding in
                        let url = store.inventory.visibility == .unavailable ? nil :
                            WebTarget.browserURL(for: binding, saved: row.record?.webTargets ?? [])
                        EndpointLine(text: binding.description, url: url)
                    }
                } else { Text("—").foregroundStyle(.secondary) }
            }.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            let targets = (store.inventory.visibility == .unavailable ? [] : row.record?.webTargets ?? []).filter { WebTarget.accepts($0, on: row.bindings) }
            if targets.count == 1 {
                Button("Open") { open(targets[0]) }
            } else if targets.count > 1 {
                Menu("Open") { ForEach(targets, id: \.self) { url in Button(url.absoluteString) { open(url) } } }.fixedSize()
            }
            Group {
                if running { Button("Stop") { Task { await store.perform(.stop, row: row) } } }
                if row.record?.startCommand != nil {
                    if !running {
                        Button("Start") { Task { await store.perform(.start, row: row) } }
                    } else if row.managed?.isRunning == true || (row.listener?.identity != nil && row.listener?.identity == row.record?.lastIdentity) {
                        Button("Restart") { Task { await store.perform(.restart, row: row) } }
                    }
                }
            }.disabled(action != nil || error != nil || !store.ready || row.controlError != nil || store.inventory.visibility != .current)
                .help(row.controlError ?? "")
            if let state = row.managed, state.isRunning || row.listener == nil {
                ManagedLogsButton(name: row.name, run: state.run)
            } else {
                ExternalServiceActions(row: row)
            }
            Button("Edit") { editing = row }.disabled(!store.ready || action != nil)
        }
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { store.message = "Could not open the web address." }
    }
}

struct EndpointLine: View {
    let text: String
    let url: URL?

    var body: some View {
        Group {
            if let url {
                Link(text, destination: url).help("Open " + url.absoluteString)
            } else {
                Text(verbatim: text)
            }
        }.font(.caption.monospaced())
    }
}

struct WorkingDirectoryLine: View {
    @EnvironmentObject private var store: AppStore
    let hostPath: String?
    var containerPath: String?
    var label = "Working directory"

    var body: some View {
        let path = containerPath ?? hostPath
        let caption = Label {
            Text(verbatim: path ?? "Working directory unavailable")
                .lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "folder")
        }
        Group {
            if let hostPath, hostPath.hasPrefix("/") {
                Button {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory),
                          isDirectory.boolValue,
                          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: hostPath) else {
                        store.message = "Could not open this folder in Finder: " + hostPath
                        return
                    }
                } label: { caption }
                .buttonStyle(.link)
                .help("Open in Finder: " + hostPath)
                .accessibilityHint("Opens the folder in Finder")
                .contextMenu {
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path ?? hostPath, forType: .string)
                    }
                }
            } else {
                caption.foregroundStyle(.secondary).textSelection(.enabled)
                    .help(path.map { label + ": " + $0 } ?? "Working directory unavailable")
            }
        }
        .font(.caption)
        .accessibilityLabel(Text("\(label): \(path ?? "unavailable")"))
    }
}

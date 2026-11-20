import AppKit
import SwiftUI

struct ProjectEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var directory = ""
    @State private var error = ""
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Project").font(.title2.bold())
            TextField("Name", text: $name)
            HStack {
                TextField("Folder", text: $directory)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || directory.isEmpty || saving)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 460)
    }

    private func create() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        let path = (directory as NSString).expandingTildeInPath
        do {
            let folder = try await Task.detached {
                var isDirectory: ObjCBool = false
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw ManagerError("Choose an existing project folder.")
                }
                return physicalDirectory(path)
            }.value
            var next = store.catalog
            next.projects.append(Project(name: name.trimmingCharacters(in: .whitespacesAndNewlines), directory: folder))
            try await store.save(next)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ServiceEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let row: ServiceRow
    @State private var record: ServiceRecord
    @State private var targets: String
    @State private var error = ""
    @State private var saving = false

    init(row: ServiceRow) {
        self.row = row
        let record = row.editableRecord
        _record = State(initialValue: record)
        _targets = State(initialValue: record.webTargets.map(\.absoluteString).joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Service").font(.title2.bold())
            LabeledContent("Service name") { TextField("Service name", text: $record.name).labelsHidden() }
            Picker("Project", selection: $record.projectID) {
                Text("Assign automatically").tag(UUID?.none)
                ForEach(store.catalog.projects) { project in Text(project.name).tag(Optional(project.id)) }
            }
            if !row.bindings.isEmpty {
                LabeledContent("Active bindings", value: row.bindings.map(\.description).joined(separator: "\n"))
            }
            LabeledContent("Working directory") { TextField("Working directory", text: field(\.directory)).labelsHidden() }
            LabeledContent("Start command") { TextField("Start command", text: field(\.startCommand)).labelsHidden() }
            Text("The confirmed command runs in /bin/sh. Use a path to run a project-specific executable.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Environment file (optional)") { TextField("Environment file (optional)", text: field(\.envFile)).labelsHidden() }
            HStack {
                TextField("Log file", text: Binding(get: { record.logPath ?? "" }, set: { record.logPath = $0.isEmpty ? nil : $0 }))
                    .accessibilityLabel("Log file")
                Button("Choose File…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK { record.logPath = panel.url?.path }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Web addresses").font(.headline)
                Text("Enter one local HTTP or HTTPS address per line, using an active host port.").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $targets).font(.system(.body, design: .monospaced)).accessibilityLabel("Web addresses")
                    .frame(height: 76).border(.quaternary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction)
                    .disabled(saving || record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 520)
    }

    private func field(_ path: WritableKeyPath<ServiceRecord, String?>) -> Binding<String> {
        Binding(get: { record[keyPath: path] ?? "" }, set: { record[keyPath: path] = $0.isEmpty ? nil : $0 })
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let bindings = store.inventory.visibility == .unavailable ? [] : store.catalog.rows(for: store.inventory.listeners, managed: store.managed)
                .first { $0.id == row.id }?.bindings ?? []
            var edited = record
            edited.name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = edited.directory {
                edited.directory = await Task.detached { physicalDirectory((path as NSString).expandingTildeInPath) }.value
            }
            if let path = edited.envFile { edited.envFile = (path as NSString).expandingTildeInPath }
            if edited.startCommand != nil, edited.directory?.hasPrefix("/") != true {
                throw ManagerError("The start profile needs an absolute working directory.")
            }
            if let path = edited.logPath {
                let expanded = (path as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else { throw ManagerError("Enter an absolute path to the log file.") }
                edited.logPath = expanded
            }
            edited.webTargets = try WebTarget.confirmed(targets, existing: record.webTargets, bindings: bindings)
            if row.managed?.isRunning != true, let listener = row.listener, let identity = listener.identity {
                edited.lastIdentity = identity
                edited.externalPorts = Set(listener.bindings)
                edited.externalSupervisor = try Predecessor.supervisor(of: identity)
            }
            var next = store.catalog
            next.services.removeAll { $0.id == edited.id }
            next.services.append(edited)
            try await store.save(next)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

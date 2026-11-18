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
            Text("Projekt anlegen").font(.title2.bold())
            TextField("Name", text: $name)
            HStack {
                TextField("Ordner", text: $directory)
                Button("Auswählen …") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Anlegen") { Task { await create() } }.keyboardShortcut(.defaultAction)
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
                    throw ManagerError("Bitte einen vorhandenen Projektordner wählen.")
                }
                return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
            Text("Dienst bearbeiten").font(.title2.bold())
            LabeledContent("Dienstname") { TextField("Dienstname", text: $record.name).labelsHidden() }
            Picker("Projekt", selection: $record.projectID) {
                Text("Automatisch zuordnen").tag(UUID?.none)
                ForEach(store.catalog.projects) { project in Text(project.name).tag(Optional(project.id)) }
            }
            if !row.bindings.isEmpty {
                LabeledContent("Aktive Bindungen", value: row.bindings.map(\.description).joined(separator: "\n"))
            }
            LabeledContent("Arbeitsordner") { TextField("Arbeitsordner", text: field(\.directory)).labelsHidden() }
            LabeledContent("Startbefehl") { TextField("Startbefehl", text: field(\.startCommand)).labelsHidden() }
            Text("Der bestätigte Befehl läuft mit /bin/sh. Projektprogramme können mit ihrem Pfad angegeben werden.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Env-Datei (optional)") { TextField("Env-Datei (optional)", text: field(\.envFile)).labelsHidden() }
            VStack(alignment: .leading, spacing: 5) {
                Text("Webziele").font(.headline)
                Text("Pro Zeile eine lokale HTTP- oder HTTPS-Adresse mit aktivem Host-Port.").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $targets).font(.system(.body, design: .monospaced)).accessibilityLabel("Webziele")
                    .frame(height: 76).border(.quaternary)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { Task { await save() } }.keyboardShortcut(.defaultAction)
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
            let bindings = store.catalog.rows(for: store.inventory.listeners, managed: store.managed)
                .first { $0.id == row.id }?.bindings ?? []
            var urls: [URL] = []
            for line in targets.split(whereSeparator: \.isNewline) {
                let address = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if address.isEmpty { continue }
                guard let url = URL(string: address),
                      record.webTargets.contains(url) || WebTarget.accepts(url, on: bindings) else {
                    throw ManagerError("Webziel benötigt eine lokale HTTP(S)-Adresse mit einem aktiven Host-Port.")
                }
                if !urls.contains(url) { urls.append(url) }
            }
            var edited = record
            edited.name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let path = edited.directory { edited.directory = (path as NSString).expandingTildeInPath }
            if let path = edited.envFile { edited.envFile = (path as NSString).expandingTildeInPath }
            if edited.startCommand != nil, edited.directory?.hasPrefix("/") != true {
                throw ManagerError("Ein Startprofil benötigt einen absoluten Arbeitsordner.")
            }
            edited.webTargets = urls
            if let identity = row.listener?.identity { edited.lastIdentity = identity }
            var next = store.catalog
            next.services.removeAll { $0.id == edited.id }
            next.services.append(edited)
            try await store.save(next)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

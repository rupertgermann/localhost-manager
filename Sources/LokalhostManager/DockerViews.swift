import AppKit
import SwiftUI

struct DockerServiceView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var docker: DockerStore
    let row: DockerRow
    @State private var editing = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.editableRecord.name).font(.body.weight(.semibold))
                Text("Docker · \(row.editableRecord.instance)").font(.caption).foregroundStyle(.secondary)
                if let id = row.container?.id {
                    Text(String(id.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary).help(id)
                }
            }.frame(minWidth: 105, maxWidth: .infinity, alignment: .leading)
            Text(row.status).font(.callout)
                .foregroundStyle(row.current?.state == "running" ? Color.teal : Color.secondary).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let current = row.current {
                    if current.ports.isEmpty {
                        Text("Kein veröffentlichter Port").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(current.ports, id: \.self) { Text($0.description).font(.caption.monospaced()) }
                } else { Text("—").foregroundStyle(.secondary) }
            }.frame(minWidth: 145, maxWidth: .infinity, alignment: .leading)
            if row.webTargets.count == 1, let target = row.webTargets.first {
                Button("Öffnen") { open(target) }
            } else if row.webTargets.count > 1 {
                Menu("Öffnen") {
                    ForEach(row.webTargets, id: \.self) { target in Button(target.absoluteString) { open(target) } }
                }.fixedSize()
            }
            Button("Zuordnen") { editing = true }.disabled(!store.ready)
        }
        .sheet(isPresented: $editing) { DockerEditor(row: row, docker: docker) }
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { store.message = "Das Webziel konnte nicht geöffnet werden." }
    }
}

private struct DockerEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    let row: DockerRow
    @ObservedObject var docker: DockerStore
    @State private var projectID: UUID?
    @State private var targets: String
    @State private var saving = false
    @State private var error = ""

    init(row: DockerRow, docker: DockerStore) {
        self.row = row
        self.docker = docker
        _projectID = State(initialValue: row.editableRecord.projectID)
        _targets = State(initialValue: row.editableRecord.webTargets.map(\.absoluteString).joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Container zuordnen").font(.title2.bold())
            LabeledContent("Container", value: row.editableRecord.name)
            Picker("Projekt", selection: $projectID) {
                Text("Automatisch zuordnen").tag(UUID?.none)
                ForEach(store.catalog.projects) { project in Text(project.name).tag(Optional(project.id)) }
            }
            Text("Zusätzliche lokale Webziele").font(.headline)
            TextEditor(text: $targets).font(.body.monospaced()).accessibilityLabel("Webziele")
                .frame(height: 76).border(.quaternary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(saving)
            }
        }.padding(24).frame(width: 450)
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            var record = row.editableRecord
            record.projectID = projectID
            let current = docker.inventory.rows(socket: docker.cli.socket, catalog: store.catalog, showStopped: true).first { $0.id == row.id }?.current
            let bindings = current?.ports.filter { $0.destination.hasSuffix("/tcp") }.map(\.host) ?? []
            var urls: [URL] = []
            for line in targets.split(whereSeparator: \.isNewline) {
                let address = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if address.isEmpty { continue }
                guard let url = URL(string: address), record.webTargets.contains(url) || WebTarget.accepts(url, on: bindings) else {
                    throw ManagerError("Webziel benötigt eine lokale HTTP(S)-Adresse mit einem veröffentlichten TCP-Port.")
                }
                if !urls.contains(url) { urls.append(url) }
            }
            record.webTargets = urls
            var next = store.catalog
            next.docker = (next.docker ?? []).filter { $0.socket != record.socket || $0.key != record.key } + [record]
            try await store.save(next)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

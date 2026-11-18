import AppKit
import SwiftUI

struct Dashboard: View {
    @EnvironmentObject var store: AppStore
    @State private var filter = ""
    @State private var systemServices = false
    @State private var creatingProject = false
    @State private var editing: ServiceRow?

    var body: some View {
        let rows = store.catalog.rows(for: store.inventory.listeners, managed: store.managed).filter(matches)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "server.rack").font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.teal).frame(width: 48, height: 48)
                    .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lokale Dienste").font(.largeTitle.bold())
                    Text("\(rows.count) Dienste · \(store.catalog.projects.count) Projekte")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { creatingProject = true } label: { Label("Projekt anlegen", systemImage: "folder.badge.plus") }
                    .disabled(!store.ready)
            }.padding(20)
            Divider()
            HStack {
                TextField("Dienste suchen", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                Toggle("Systemdienste", isOn: $systemServices).toggleStyle(.checkbox)
                Button { Task { await store.refresh() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                    .disabled(store.refreshing).keyboardShortcut("r")
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(store.catalog.projects) { project in
                        let services = rows.filter { $0.projectID == project.id }
                        if !services.isEmpty || filter.isEmpty { group(project.name, rows: services, project: project) }
                    }
                    let unassigned = rows.filter { $0.projectID == nil }
                    if !unassigned.isEmpty { group("Unzugeordnet", rows: unassigned) }
                    if rows.isEmpty {
                        Text(store.refreshing ? "Listener werden gelesen …" : "Keine passenden Dienste gefunden.")
                            .foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            if let message = store.message ?? store.inventory.warning {
                Label(message, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    .foregroundStyle(.primary).font(.callout).padding(10)
            } else {
                Label("Sichtbare TCP-Listener des lokalen Macs", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary).font(.caption).padding(10)
            }
        }
        .frame(minWidth: 780, minHeight: 440)
        .sheet(isPresented: $creatingProject) { ProjectEditor() }
        .sheet(item: $editing) { ServiceEditor(row: $0) }
        .task {
            await store.load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await store.refresh()
            }
        }
    }

    private func matches(_ row: ServiceRow) -> Bool {
        if !systemServices && row.listener?.isSystem == true { return false }
        if filter.isEmpty { return true }
        let text = [row.name, row.listener?.directory ?? "", row.listener?.pid.description ?? ""] + row.bindings.map(\.description)
        return text.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func group(_ title: String, rows: [ServiceRow], project: Project? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: "folder").font(.headline)
                Spacer()
                Text("\(rows.count)").foregroundStyle(.secondary).monospacedDigit()
                if let project {
                    Button("Dienst anlegen") {
                        let record = ServiceRecord(name: "", projectID: project.id, directory: project.directory)
                        editing = ServiceRow(record: record, projectID: project.id)
                    }.disabled(!store.ready)
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if rows.isEmpty { Text("Keine Dienste").foregroundStyle(.secondary).padding(12) }
            ForEach(rows) { row in
                service(row).padding(.horizontal, 12).padding(.vertical, 9)
                if row.id != rows.last?.id { Divider() }
            }
        }.background(.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
    }

    private func service(_ row: ServiceRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.body.weight(.semibold))
                if let listener = row.listener {
                    Text("PID \(listener.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }.frame(minWidth: 95, maxWidth: .infinity, alignment: .leading)
            let busy = row.record.map { store.starting.contains($0.id) } ?? false
            let error = row.record.flatMap { store.managedErrors[$0.id] }
            let running = row.listener != nil || row.managed?.isRunning == true
            let status = busy ? "Startet …" : error != nil ? "Unbekannt" : running ? "Läuft" : row.managed?.description ?? "Gestoppt"
            Label(status, systemImage: running ? "circle.fill" : "stop.circle")
                .font(.callout).foregroundStyle(running ? Color.teal : Color.secondary).frame(width: 92, alignment: .leading).help(error ?? status)
            VStack(alignment: .leading, spacing: 2) {
                if !row.bindings.isEmpty {
                    ForEach(row.bindings, id: \.self) { Text($0.description).font(.system(.caption, design: .monospaced)) }
                } else { Text("—").foregroundStyle(.secondary) }
            }.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            let targets = (row.record?.webTargets ?? []).filter { WebTarget.accepts($0, on: row.bindings) }
            if targets.count == 1 {
                Button("Öffnen") { open(targets[0]) }
            } else if targets.count > 1 {
                Menu("Öffnen") { ForEach(targets, id: \.self) { url in Button(url.absoluteString) { open(url) } } }.fixedSize()
            }
            if let record = row.record, record.startCommand != nil, !running {
                Button("Starten") { Task { await store.start(record) } }.disabled(busy || error != nil || !store.ready)
            }
            if let state = row.managed, state.isRunning || row.listener == nil {
                ManagedLogsButton(name: row.name, run: state.run)
            } else {
                ExternalServiceActions(row: row)
            }
            Button("Bearbeiten") { editing = row }.disabled(!store.ready)
        }
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { store.message = "Das Webziel konnte nicht geöffnet werden." }
    }
}

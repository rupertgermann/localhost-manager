import AppKit
import SwiftUI

struct Dashboard: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var docker = DockerStore()
    @State private var showStopped = false
    @State private var filter = ""
    @State private var systemServices = false
    @State private var creatingProject = false
    @State private var editing: ServiceRow?

    var body: some View {
        let rows = store.catalog.rows(for: docker.inventory.nativeListeners(store.inventory.listeners)).filter(matches)
        let containers = docker.inventory.rows(socket: docker.cli.socket, catalog: store.catalog, showStopped: showStopped).filter { row in
            let text = [row.editableRecord.name, row.editableRecord.instance, row.container?.id ?? ""] + (row.container?.ports.map(\.description) ?? [])
            return filter.isEmpty || text.contains { $0.localizedCaseInsensitiveContains(filter) }
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "server.rack").font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.teal).frame(width: 48, height: 48)
                    .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lokale Dienste").font(.largeTitle.bold())
                    Text("\(rows.count + containers.count) Dienste · \(store.catalog.projects.count) Projekte")
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
                Toggle("Gestoppte Container", isOn: $showStopped).toggleStyle(.checkbox)
                Toggle("Systemdienste", isOn: $systemServices).toggleStyle(.checkbox)
                Button { Task { await store.refresh() }; Task { await docker.refresh() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                    .disabled(store.refreshing).keyboardShortcut("r")
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(store.catalog.projects) { project in
                        let services = rows.filter { $0.projectID == project.id }
                        let assigned = containers.filter { $0.projectID == project.id }
                        if !services.isEmpty || !assigned.isEmpty || filter.isEmpty { group(project.name, rows: services, containers: assigned) }
                    }
                    let unassigned = rows.filter { $0.projectID == nil }
                    let automatic = containers.filter { $0.projectID == nil }
                    let composeProjects = Set(automatic.compactMap { $0.editableRecord.composeProject }).sorted()
                    ForEach(composeProjects, id: \.self) { name in
                        group(name, rows: [], containers: automatic.filter { $0.editableRecord.composeProject == name })
                    }
                    let standalone = automatic.filter { $0.editableRecord.composeProject == nil }
                    if !unassigned.isEmpty || !standalone.isEmpty { group("Unzugeordnet", rows: unassigned, containers: standalone) }
                    if rows.isEmpty && containers.isEmpty {
                        Text(store.refreshing ? "Listener werden gelesen …" : "Keine passenden Dienste gefunden.")
                            .foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            if let error = docker.inventory.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled).padding(10)
            } else if docker.inventory.available && docker.inventory.containers.isEmpty {
                Text("Docker: keine Container").font(.caption).foregroundStyle(.secondary).padding(10)
            }
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

    private func matches(_ row: ServiceRow) -> Bool {
        if !systemServices && row.listener?.isSystem == true { return false }
        if filter.isEmpty { return true }
        let text = [row.name, row.listener?.directory ?? "", row.listener?.pid.description ?? ""] + (row.listener?.bindings.map(\.description) ?? [])
        return text.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    private func group(_ title: String, rows: [ServiceRow], containers: [DockerRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(title, systemImage: "folder").font(.headline)
                Spacer()
                Text("\(rows.count + containers.count)").foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if rows.isEmpty && containers.isEmpty { Text("Keine Dienste").foregroundStyle(.secondary).padding(12) }
            ForEach(rows) { row in
                service(row).padding(.horizontal, 12).padding(.vertical, 9)
                if row.id != rows.last?.id || !containers.isEmpty { Divider() }
            }
            ForEach(containers) { row in
                DockerServiceView(docker: docker, row: row).padding(.horizontal, 12).padding(.vertical, 9)
                if row.id != containers.last?.id { Divider() }
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
            Label(row.listener == nil ? "Gestoppt" : "Läuft", systemImage: row.listener == nil ? "stop.circle" : "circle.fill")
                .font(.callout).foregroundStyle(row.listener == nil ? Color.secondary : Color.teal).frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let listener = row.listener {
                    ForEach(listener.bindings, id: \.self) { Text($0.description).font(.system(.caption, design: .monospaced)) }
                } else { Text("—").foregroundStyle(.secondary) }
            }.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            let targets = (row.record?.webTargets ?? []).filter { WebTarget.accepts($0, on: row.listener?.bindings ?? []) }
            if targets.count == 1 {
                Button("Öffnen") { open(targets[0]) }
            } else if targets.count > 1 {
                Menu("Öffnen") { ForEach(targets, id: \.self) { url in Button(url.absoluteString) { open(url) } } }.fixedSize()
            }
            ExternalServiceActions(row: row)
            Button("Bearbeiten") { editing = row }.disabled(!store.ready)
        }
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { store.message = "Das Webziel konnte nicht geöffnet werden." }
    }
}

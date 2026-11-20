import AppKit
import SwiftUI

struct DockerServiceView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var docker: DockerStore
    let row: DockerRow
    let showLogs: (DockerContainer) -> Void
    @State private var editing = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.editableRecord.name).font(.body.weight(.semibold))
                HStack {
                    ProcessCategory.docker.badge
                    Text(row.editableRecord.instance).font(.caption).foregroundStyle(.secondary)
                }
                if let hostDirectory = row.editableRecord.directory {
                    WorkingDirectoryLine(hostPath: hostDirectory, label: "Compose project directory on this Mac")
                }
                WorkingDirectoryLine(hostPath: row.container?.mountedWorkingDirectory, containerPath: row.container?.containerDirectory, label: "Working directory inside container")
                if let id = row.container?.id {
                    Text(String(id.prefix(12))).font(.caption.monospaced()).foregroundStyle(.secondary).help(id)
                }
            }.frame(minWidth: 105, maxWidth: .infinity, alignment: .leading)
            Text(row.status).font(.callout)
                .foregroundStyle(row.current?.state == "running" ? Color.teal : Color.secondary).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let current = row.current {
                    if current.ports.isEmpty {
                        Text("No published port").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(current.ports, id: \.self) { port in
                        let url = current.state == "running" ?
                            WebTarget.browserURL(for: port.host, saved: row.webTargets, containerPort: port.destination) : nil
                        EndpointLine(text: port.description, url: url)
                    }
                } else { Text("—").foregroundStyle(.secondary) }
            }.frame(minWidth: 145, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    if let container = row.container {
                        let busy = docker.busy.contains(container.id)
                        if busy { ProgressView().controlSize(.small).accessibilityLabel("Docker action in progress") }
                        ForEach(DockerAction.allCases.filter { $0.accepts(container.state) }, id: \.self) { action in
                            Button(action.title) {
                                Task {
                                    do { try await docker.perform(action, on: row) }
                                    catch { store.message = "\(row.editableRecord.name): \(error.localizedDescription)" }
                                }
                            }.disabled(row.current == nil || busy)
                        }
                    }
                }
                HStack {
                    if row.webTargets.count == 1, let target = row.webTargets.first {
                        Button("Open") { open(target) }
                    } else if row.webTargets.count > 1 {
                        Menu("Open") {
                            ForEach(row.webTargets, id: \.self) { target in Button(target.absoluteString) { open(target) } }
                        }.fixedSize()
                    }
                    Button("Logs") { if let current = row.current { showLogs(current) } }.disabled(row.current == nil)
                    Button("Assign") { editing = true }.disabled(!store.ready)
                }
            }
        }
        .sheet(isPresented: $editing) { DockerEditor(row: row, docker: docker) }
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { store.message = "Could not open the web address." }
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
            Text("Assign Container").font(.title2.bold())
            LabeledContent("Container", value: row.editableRecord.name)
            Picker("Project", selection: $projectID) {
                Text("Assign automatically").tag(UUID?.none)
                ForEach(store.catalog.projects) { project in Text(project.name).tag(Optional(project.id)) }
            }
            Text("Local web addresses").font(.headline)
            TextEditor(text: $targets).font(.body.monospaced()).accessibilityLabel("Web addresses")
                .frame(height: 76).border(.quaternary)
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { Task { await save() } }.keyboardShortcut(.defaultAction).disabled(saving)
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
            record.webTargets = try WebTarget.confirmed(targets, existing: record.webTargets, bindings: bindings)
            var next = store.catalog
            next.docker = (next.docker ?? []).filter { $0.socket != record.socket || $0.key != record.key } + [record]
            try await store.save(next)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct DockerLogPanel: View {
    @ObservedObject var docker: DockerStore
    let container: DockerContainer
    @Environment(\.dismiss) private var dismiss
    @State private var output: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logs · \(container.name)").font(.title2.bold())
            Text("\(container.instanceDescription) · \(container.id.prefix(12))").foregroundStyle(.secondary)
            if let failure = docker.inventory.error {
                Text("Docker disconnected: " + failure).textSelection(.enabled)
            } else if let error {
                Text("Could not read container logs: " + error).textSelection(.enabled)
            } else if let output {
                if output.isEmpty {
                    Text("No log output yet.").foregroundStyle(.secondary)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(verbatim: output).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            } else {
                ProgressView("Reading logs…")
            }
            Spacer(minLength: 0)
            HStack {
                Text("Last 200 lines, up to 64 KiB").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 620, height: 410)
        .task(id: container.id) {
            while !Task.isCancelled {
                do {
                    let tail = try await docker.cli.logs(id: container.id)
                    try Task.checkCancellation()
                    output = tail
                    error = nil
                } catch {
                    guard !Task.isCancelled else { break }
                    output = nil
                    self.error = error.localizedDescription
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
}

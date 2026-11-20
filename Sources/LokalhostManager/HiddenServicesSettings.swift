import SwiftUI

struct HiddenServicesSettings: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let rows: [ServiceRow]
    let containers: [DockerRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.title2.bold())
            Text("Hidden Services").font(.headline)
            let rules = store.catalog.hiddenServices ?? []
            if rules.isEmpty {
                Text("No services hidden. Use the eye menu in a service row to hide it by name or port.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("A service stays hidden while any rule matches.")
                    .foregroundStyle(.secondary)
                List(rules, id: \.self) { rule in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(title(for: rule)).fontWeight(.semibold)
                            Spacer()
                            Button("Remove Rule") {
                                Task { await store.setHidden(rule, hidden: false) }
                            }
                            .disabled(store.saving)
                            .accessibilityLabel("Remove rule for \(title(for: rule))")
                        }
                        let local = rows.filter { rule.matches(name: $0.name, ports: $0.bindings.map(\.port)) }
                        let docker = containers.filter {
                            rule.matches(name: $0.editableRecord.name, ports: $0.container?.ports.map(\.host.port) ?? [])
                        }
                        ForEach(local) { row in
                            match(row.name, ports: row.bindings.map(\.port))
                        }
                        ForEach(docker) { row in
                            match(row.editableRecord.name, ports: row.container?.ports.map(\.host.port) ?? [])
                        }
                        if local.isEmpty && docker.isEmpty {
                            Text("No current matches").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
            if let message = store.message {
                Text(message).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500, height: 360)
    }

    private func title(for rule: HiddenServiceRule) -> String {
        switch rule {
        case .name(let name): "Name “\(name)”"
        case .port(let port): "Port \(port.formatted(.number.grouping(.never)))"
        }
    }

    private func match(_ name: String, ports: [Int]) -> some View {
        let portList = Set(ports).sorted().map { String($0) }.joined(separator: ", ")
        return Text(portList.isEmpty ? name : "\(name) · \(portList)")
            .font(.caption).foregroundStyle(.secondary)
    }
}

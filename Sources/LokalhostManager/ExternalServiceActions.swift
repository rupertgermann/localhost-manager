import SwiftUI

struct ExternalServiceActions: View {
    @State private var showingLogs = false
    let row: ServiceRow

    var body: some View {
        Button("Logs") { showingLogs = true }
            .sheet(isPresented: $showingLogs) { FileLogView(title: row.name, path: row.record?.logPath) }
    }
}

struct FileLogView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let path: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Logs · \(title)").font(.title2.bold())
            FileLogContents(path: path)
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 620, height: 410)
    }
}

struct FileLogContents: View {
    let path: String?
    @State private var content: FileLog?
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let path { Text(path).font(.caption).textSelection(.enabled) }
                Spacer()
                Button("Refresh") { revision += 1 }
            }
            ScrollView {
                Group {
                    switch content {
                    case nil: Text("Reading log file…")
                    case .empty: Text("No output yet")
                    case .unavailable(let reason): Text(reason)
                    case .output(let text, let truncated):
                        VStack(alignment: .leading, spacing: 6) {
                            if truncated { Text("Last 64 KiB").font(.caption).foregroundStyle(.secondary) }
                            Text(verbatim: text).font(.system(.body, design: .monospaced))
                        }
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
        }
        .task(id: revision) {
            content = nil
            let result = await Task.detached { FileLog.read(path: path) }.value
            if !Task.isCancelled { content = result }
        }.id(path)
    }
}

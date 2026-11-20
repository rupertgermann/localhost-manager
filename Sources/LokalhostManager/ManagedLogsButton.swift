import SwiftUI

struct ManagedLogsButton: View {
    @EnvironmentObject private var store: AppStore
    let name: String
    let run: ManagedRun
    @State private var showing = false
    @State private var stderr = false

    var body: some View {
        Button("Logs") { showing = true }
            .sheet(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Logs · \(name)").font(.title2.bold())
                    Picker("Output", selection: $stderr) { Text("stdout").tag(false); Text("stderr").tag(true) }
                        .pickerStyle(.segmented)
                    let path = ManagedJobs(directory: store.dataDirectory).log(run, stderr: stderr).path
                    FileLogContents(path: path).id(path)
                    HStack {
                        Spacer()
                        Button("Close") { showing = false }.keyboardShortcut(.cancelAction)
                    }
                }.padding(20).frame(width: 620, height: 410)
            }
    }
}

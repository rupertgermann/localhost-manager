import SwiftUI

@main
struct LokalhostManagerApp: App {
    @StateObject private var store = AppStore()
    var body: some Scene {
        Window("Lokalhost Manager", id: "overview") {
            Dashboard().environmentObject(store)
        }.defaultSize(width: 1000, height: 680)
    }
}

import SwiftUI

@main
struct SyncHubHelperApp: App {
    @StateObject private var engine = HelperEngine.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
        }
    }
}

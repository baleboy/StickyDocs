import SwiftUI

@main
struct StickyDocsApp: App {
    init() {
        // Materialize the shared controller eagerly so it observes app lifecycle
        // from launch onwards.
        _ = AppController.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { try? AppController.shared.restoreOpenStickies() }
        }
    }
}

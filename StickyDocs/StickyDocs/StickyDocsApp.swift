import SwiftUI
import AppKit

@main
struct StickyDocsApp: App {
    init() {
        // Materialize the shared controller eagerly so it observes app lifecycle
        // from launch onwards.
        _ = AppController.shared
    }

    var body: some Scene {
        MenuBarExtra("StickyDocs", systemImage: "note.text") {
            MenuBarContent()
        }

        WindowGroup {
            ContentView()
                .task { try? AppController.shared.restoreOpenStickies() }
        }
        .commands {
            CommandMenu("Format") {
                Button("Bold") {
                    NSApp.sendAction(Selector(("toggleBold:")), to: nil, from: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Italic") {
                    NSApp.sendAction(Selector(("toggleItalic:")), to: nil, from: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
                Button("Underline") {
                    NSApp.sendAction(Selector(("toggleUnderline:")), to: nil, from: nil)
                }
                .keyboardShortcut("u", modifiers: .command)
            }
        }
    }
}

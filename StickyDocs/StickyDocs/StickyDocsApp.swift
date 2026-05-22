import SwiftUI
import AppKit

@main
struct StickyDocsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Materialize the shared controller eagerly so it observes app lifecycle
        // from launch onwards.
        _ = AppController.shared
    }

    var body: some Scene {
#if DEBUG
        // The auth + round-trip harness window. Only present in debug builds —
        // release users shouldn't see "Save creds for tests" et al. on every
        // launch. Launch-time work (onboarding, sticky restore, initial pull)
        // moved to AppDelegate.applicationDidFinishLaunching so it runs even
        // without this window.
        Window("StickyDocs (Debug)", id: "main") {
            ContentView()
        }
#endif

        MenuBarExtra("StickyDocs", systemImage: "note.text") {
            MenuBarContent()
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppController.shared.presentOnboardingIfNeeded()
            try? AppController.shared.restoreOpenStickies()
            await AppController.shared.pullAllFromDrive()
        }
    }
}

import SwiftUI
import AppKit

@main
struct StickyDocsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Materialize the shared controller eagerly so it observes app lifecycle
        // from launch onwards. Same for the Sparkle updater — instantiating it
        // here starts the scheduled background update checks.
        _ = AppController.shared
        _ = Updater.shared
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
            CommandGroup(replacing: .appInfo) {
                Button("About StickyDocs") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: StickyDocsApp.aboutCredits
                    ])
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            StickyDocsCommands()
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

    // Credits string shown by the standard About panel. App name, version,
    // and build come from the bundle automatically; this fills the area
    // below with a tagline, project link, and third-party acknowledgements.
    static var aboutCredits: NSAttributedString {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let result = NSMutableAttributedString()

        result.append(NSAttributedString(
            string: "Sticky notes on your desktop, synced to Google Docs.\n\n",
            attributes: [.font: body]
        ))

        let project = "https://github.com/baleboy/StickyDocs"
        result.append(NSAttributedString(
            string: project + "\n\n",
            attributes: [
                .font: body,
                .link: URL(string: project) as Any
            ]
        ))

        result.append(NSAttributedString(string: "Built with\n", attributes: [.font: bold]))
        let credits: [(String, String)] = [
            ("GRDB.swift", "https://github.com/groue/GRDB.swift"),
            ("Sparkle", "https://sparkle-project.org")
        ]
        for (name, url) in credits {
            result.append(NSAttributedString(string: "• ", attributes: [.font: body]))
            result.append(NSAttributedString(
                string: name,
                attributes: [.font: body, .link: URL(string: url) as Any]
            ))
            result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        }

        return result
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppController.shared.presentOnboardingIfNeeded()
            try? AppController.shared.restoreOpenStickies()
            try? AppController.shared.createInitialStickyIfNeeded()
            await AppController.shared.pullAllFromDrive()
        }
    }

    // Dock-icon fallback: in Release builds we hide the debug Window, so if
    // the user's menu bar is full (notched Macs with corporate tooling are
    // notorious) and the MenuBarExtra icon doesn't fit, they have no way to
    // reach the app. Clicking the dock icon now opens the All Stickies panel,
    // which has its own New Sticky button.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in
                AppController.shared.showAllStickiesPanel()
            }
        }
        return true
    }
}

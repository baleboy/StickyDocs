import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var debug = DebugSettings.shared
    @ObservedObject private var app = AppController.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Button("New Sticky") {
            if app.isOnboardingComplete {
                _ = try? AppController.shared.newSticky()
            } else {
                AppController.shared.presentOnboardingIfNeeded()
            }
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])

        Button("Show All Stickies") {
            AppController.shared.showAllStickiesPanel()
        }

        // Label carries the shortcut instead of .keyboardShortcut: the hot key
        // is registered globally in AppController, and a SwiftUI shortcut would
        // fire a second time whenever StickyDocs itself is frontmost.
        Toggle("Keep Stickies on Top (⌥⌘S)", isOn: $settings.keepOnTop)

        Button("Sync Now") {
            Task { await AppController.shared.syncNow() }
        }
        .disabled(!auth.isSignedIn)

        Button("Open Stickies Folder in Drive") {
            AppController.shared.openStickiesFolderInBrowser()
        }
        .disabled(!auth.isSignedIn)

        Divider()

        if auth.isSignedIn {
            Button("Sign Out...") { AppController.shared.confirmAndSignOut() }
        } else {
            Button("Sign In with Google...") {
                Task { _ = try? await auth.signIn() }
            }
        }

        Divider()

        Button("Check for Updates...") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

        Toggle("Receive Alpha Updates", isOn: $updater.alphaChannelEnabled)

#if DEBUG
        Divider()

        Menu("Debug") {
            Toggle("Show Sticky Size", isOn: $debug.showStickySize)

            Button("Reset All Local Data...") {
                let alert = NSAlert()
                alert.messageText = "Reset all local data?"
                alert.informativeText = "Deletes the local sticky database and signs you out. Google Docs in Drive are left untouched."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Reset")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    AppController.shared.resetAllLocalData()
                }
            }
        }
#endif

        Divider()

        Button("Quit StickyDocs") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// Mirrors MenuBarContent into the regular application menu, so the same actions
// remain reachable when the MenuBarExtra icon is hidden (e.g. crowded menu bars
// on notched Macs) and the app is in the foreground. Quit and Format are
// already provided by the system / Format CommandMenu, so they're omitted here.
struct StickyDocsCommands: Commands {
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var debug = DebugSettings.shared
    @ObservedObject private var app = AppController.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("StickyDocs Help") {
                if let url = URL(string: "https://baleboy.github.io/StickyDocs/help.html") {
                    NSWorkspace.shared.open(url)
                }
            }
            .keyboardShortcut("?", modifiers: .command)

            Divider()

            Button("Report an Issue...") {
                if let url = URL(string: "https://github.com/baleboy/StickyDocs/issues") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button("New Sticky") {
                if app.isOnboardingComplete {
                    _ = try? AppController.shared.newSticky()
                } else {
                    AppController.shared.presentOnboardingIfNeeded()
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }

        CommandMenu("Stickies") {
            Button("Show All Stickies") {
                AppController.shared.showAllStickiesPanel()
            }

            Toggle("Keep Stickies on Top (⌥⌘S)", isOn: $settings.keepOnTop)

            Button("Sync Now") {
                Task { await AppController.shared.syncNow() }
            }
            .disabled(!auth.isSignedIn)

            Button("Open Stickies Folder in Drive") {
                AppController.shared.openStickiesFolderInBrowser()
            }
            .disabled(!auth.isSignedIn)

            Divider()

            if auth.isSignedIn {
                Button("Sign Out...") { AppController.shared.confirmAndSignOut() }
            } else {
                Button("Sign In with Google...") {
                    Task { _ = try? await auth.signIn() }
                }
            }

            Divider()

            Button("Check for Updates...") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)

            Toggle("Receive Alpha Updates", isOn: $updater.alphaChannelEnabled)

#if DEBUG
            Divider()

            Menu("Debug") {
                Toggle("Show Sticky Size", isOn: $debug.showStickySize)

                Button("Reset All Local Data...") {
                    let alert = NSAlert()
                    alert.messageText = "Reset all local data?"
                    alert.informativeText = "Deletes the local sticky database and signs you out. Google Docs in Drive are left untouched."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Reset")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        AppController.shared.resetAllLocalData()
                    }
                }
            }
#endif
        }
    }
}

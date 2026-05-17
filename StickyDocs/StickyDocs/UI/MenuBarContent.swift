import SwiftUI
import AppKit

struct MenuBarContent: View {
    @ObservedObject private var auth = AuthService.shared

    var body: some View {
        Button("New Sticky") {
            _ = try? AppController.shared.newSticky()
        }
        .keyboardShortcut("n", modifiers: [.command, .shift])
        .disabled(!auth.isSignedIn)

        Button("Show All Stickies") {
            AppController.shared.showAllStickiesPanel()
        }

        Button("Sync Now") {
            Task { await AppController.shared.syncAllPending() }
        }
        .disabled(!auth.isSignedIn)

        Button("Open Stickies Folder in Drive") {
            AppController.shared.openStickiesFolderInBrowser()
        }
        .disabled(!auth.isSignedIn)

        Divider()

        if auth.isSignedIn {
            Button("Sign Out") { try? auth.signOut() }
        } else {
            Button("Sign In with Google...") {
                Task { _ = try? await auth.signIn() }
            }
        }

        Divider()

        Menu("Debug") {
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

        Divider()

        Button("Quit StickyDocs") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

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

        Button("Quit StickyDocs") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

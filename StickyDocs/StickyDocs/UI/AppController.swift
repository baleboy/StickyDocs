import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppController {
    static let shared = AppController()

    let store: StickyStore
    let engine: SyncEngine
    private(set) var isTerminating = false
    private var windowControllers: [String: StickyWindowController] = [:]
    private var allStickiesWindow: NSWindow?

    private init() {
        do {
            self.store = try StickyStore.onDisk()
        } catch {
            fatalError("Failed to open StickyStore: \(error)")
        }
        let driveClient = GoogleDriveClient(accessToken: { try await AuthService.shared.accessToken() })
        let docsClient = GoogleDocsClient(accessToken: { try await AuthService.shared.accessToken() })
        let folderIdCache = FolderIdCache(store: store, drive: driveClient)

        let deps = SyncEngine.Dependencies(
            createDoc: { title in
                let folderId = try await folderIdCache.id()
                return try await driveClient.createDoc(title: title, parentFolderId: folderId)
            },
            exportAsHTML: { try await driveClient.exportAsHTML(docId: $0) },
            fetchRevisionId: { try await docsClient.fetchRevisionId(docId: $0) },
            pushBody: { docId, content in try await docsClient.replaceDocumentBody(docId: docId, with: content) },
            deleteDoc: { try await driveClient.deleteFile(id: $0) },
            ensureStickiesFolder: { _ = try await folderIdCache.id() },
            isTrashed: { try await driveClient.isTrashed(docId: $0) }
        )
        self.engine = SyncEngine(store: store, deps: deps)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isTerminating = true
        }
    }

    func newSticky() throws -> Sticky {
        let sticky = try engine.createLocalSticky()
        showWindow(for: sticky)
        return sticky
    }

    func showWindow(for sticky: Sticky) {
        if !sticky.isOpen, var s = try? store.fetch(id: sticky.id) {
            s.isOpen = true
            try? store.upsert(s)
        }
        if let existing = windowControllers[sticky.id] {
            existing.showWindow(nil)
            return
        }
        let controller = StickyWindowController(sticky: sticky, engine: engine, onClose: { [weak self] id in
            self?.windowControllers.removeValue(forKey: id)
        })
        windowControllers[sticky.id] = controller
        controller.showWindow(nil)
    }

    func restoreOpenStickies() throws {
        for sticky in try store.allOpen() {
            showWindow(for: sticky)
        }
    }

    func syncAllPending() async {
        let pending = (try? store.pendingPushes()) ?? []
        NSLog("[StickyDocs] syncAllPending: \(pending.count) pending sticky/stickies")
        for sticky in pending {
            do {
                try await engine.push(stickyId: sticky.id)
                NSLog("[StickyDocs] push OK for sticky \(sticky.id)")
            } catch {
                NSLog("[StickyDocs] push FAILED for sticky \(sticky.id): \(error)")
            }
        }
    }

    // Pulls every provisioned sticky from Drive. Used on app launch and as
    // part of "Sync Now" so remote edits made via docs.google.com surface
    // in the app. No-op when signed out.
    func pullAllFromDrive() async {
        guard AuthService.shared.isSignedIn else { return }
        let all = (try? store.allActive()) ?? []
        let provisioned = all.filter { $0.googleDocId != nil }
        NSLog("[StickyDocs] pullAllFromDrive: \(provisioned.count) sticky/stickies")
        for sticky in provisioned {
            do {
                let outcome = try await engine.pull(stickyId: sticky.id)
                NSLog("[StickyDocs] pull \(outcome) for sticky \(sticky.id)")
            } catch {
                NSLog("[StickyDocs] pull FAILED for sticky \(sticky.id): \(error)")
            }
        }
    }

    // Sync Now: pull first so remote edits land before we push any local
    // pending. If pull picks up a remote change for a sticky that also had
    // a pending local edit, the conflict path stashes local into
    // conflict_backup_html and pendingPush is cleared - so the subsequent
    // push pass simply skips it.
    func syncNow() async {
        await pullAllFromDrive()
        await syncAllPending()
    }

    func showAllStickiesPanel() {
        if allStickiesWindow == nil {
            let hosting = NSHostingController(rootView: AllStickiesView(store: store) { [weak self] sticky in
                self?.showWindow(for: sticky)
            })
            let window = NSWindow(contentViewController: hosting)
            window.title = "All Stickies"
            window.setContentSize(NSSize(width: 360, height: 480))
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            allStickiesWindow = window
        }
        // Equivalent to a dock-icon click: brings the app to the foreground
        // and orders all its windows forward. Plain NSApp.activate is flaky
        // from a MenuBarExtra action context.
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        allStickiesWindow?.makeKeyAndOrderFront(nil)
    }

    func resetAllLocalData() {
        for controller in windowControllers.values {
            controller.close()
        }
        windowControllers.removeAll()
        allStickiesWindow?.close()
        allStickiesWindow = nil
        try? store.wipeAll()
        try? AuthService.shared.signOut()
    }

    func openStickiesFolderInBrowser() {
        let id = (try? store.getAppState(key: "stickies_folder_id")) ?? nil
        if let id, let url = URL(string: "https://drive.google.com/drive/folders/\(id)") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://drive.google.com/") {
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private final class FolderIdCache {
    private static let storeKey = "stickies_folder_id"
    private static let folderName = "Stickies"

    private let store: StickyStore
    private let drive: GoogleDriveClient
    private var cached: String?

    init(store: StickyStore, drive: GoogleDriveClient) {
        self.store = store
        self.drive = drive
        self.cached = try? store.getAppState(key: Self.storeKey)
    }

    func id() async throws -> String {
        if let cached { return cached }
        let id = try await drive.findOrCreateFolder(named: Self.folderName)
        cached = id
        try? store.setAppState(key: Self.storeKey, value: id)
        return id
    }
}

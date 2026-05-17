import Foundation
import AppKit
import SwiftUI

@MainActor
final class AppController {
    static let shared = AppController()

    let store: StickyStore
    let engine: SyncEngine
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
    }

    func newSticky() throws -> Sticky {
        let sticky = try engine.createLocalSticky()
        showWindow(for: sticky)
        return sticky
    }

    func showWindow(for sticky: Sticky) {
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
        for sticky in try store.allActive() {
            showWindow(for: sticky)
        }
    }

    func syncAllPending() async {
        let pending = (try? store.pendingPushes()) ?? []
        for sticky in pending {
            try? await engine.push(stickyId: sticky.id)
        }
    }

    func showAllStickiesPanel() {
        if let existing = allStickiesWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
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
        window.makeKeyAndOrderFront(nil)
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

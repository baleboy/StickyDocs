import Foundation
import AppKit

@MainActor
final class AppController {
    static let shared = AppController()

    let store: StickyStore
    let engine: SyncEngine
    private var windowControllers: [String: StickyWindowController] = [:]

    private init() {
        do {
            self.store = try StickyStore.onDisk()
        } catch {
            fatalError("Failed to open StickyStore: \(error)")
        }
        let driveClient = GoogleDriveClient(accessToken: { try await AuthService.shared.accessToken() })
        let docsClient = GoogleDocsClient(accessToken: { try await AuthService.shared.accessToken() })
        let deps = SyncEngine.Dependencies(
            createDoc: { title in try await driveClient.createDoc(title: title) },
            exportAsHTML: { try await driveClient.exportAsHTML(docId: $0) },
            fetchRevisionId: { try await docsClient.fetchRevisionId(docId: $0) },
            pushBody: { docId, content in try await docsClient.replaceDocumentBody(docId: docId, with: content) },
            deleteDoc: { try await driveClient.deleteFile(id: $0) }
        )
        self.engine = SyncEngine(store: store, deps: deps)
    }

    func newSticky() throws -> Sticky {
        let sticky = try engine.createLocalSticky()
        showWindow(for: sticky)
        Task { [engine] in
            try? await engine.provisionDocIfNeeded(stickyId: sticky.id)
        }
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
}

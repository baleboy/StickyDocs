import Foundation
import AppKit

// Orchestrates push/pull between the local StickyStore and Google Docs/Drive.
//
// v1 scope:
//   - createSticky: create local row + Drive Doc tagged with appProperties
//   - updateContent: write local + mark pending_push
//   - push: send pending content via Docs batchUpdate, update lastSyncedHTML
//   - pull: fetch Doc as HTML; on conflict (revisionId advanced + local dirty),
//     stash local into conflict_backup_html and accept remote
//   - delete: soft-delete locally; optionally also trash the Doc
//
// Deferred (v2+): debounced push timer, changes.list polling, network state
// monitoring, exponential backoff, conflict toast event stream.
@MainActor
final class SyncEngine {

    struct Dependencies {
        var createDoc: (_ title: String) async throws -> String                          // -> docId
        var exportAsHTML: (_ docId: String) async throws -> String
        var fetchRevisionId: (_ docId: String) async throws -> String?
        var pushBody: (_ docId: String, _ content: NSAttributedString) async throws -> Void
        var deleteDoc: (_ docId: String) async throws -> Void
        var ensureStickiesFolder: () async throws -> Void = {}
    }

    let store: StickyStore
    let deps: Dependencies

    init(store: StickyStore, deps: Dependencies) {
        self.store = store
        self.deps = deps
    }

    // MARK: - Operations

    // Creates a Sticky locally without touching the network. The Doc is
    // provisioned lazily by provisionDocIfNeeded so the window can appear
    // instantly. Until provisioning succeeds, googleDocId is nil and any
    // local edits accumulate in pending_push.
    func createLocalSticky(title: String = "Untitled sticky") throws -> Sticky {
        var sticky = Sticky.makeNew(title: title)
        sticky.pendingPush = true
        try store.upsert(sticky)
        return sticky
    }

    func provisionDocIfNeeded(stickyId: String) async throws {
        guard var sticky = try store.fetch(id: stickyId), sticky.googleDocId == nil else { return }
        try await deps.ensureStickiesFolder()
        let docId = try await deps.createDoc(sticky.title.isEmpty ? "Untitled sticky" : sticky.title)
        sticky.googleDocId = docId
        sticky.lastRevisionId = try await deps.fetchRevisionId(docId)
        try store.upsert(sticky)
    }

    // Convenience for tests / scripted flows: creates local + provisions Doc.
    func createSticky(title: String = "Untitled sticky") async throws -> Sticky {
        let sticky = try createLocalSticky(title: title)
        try await provisionDocIfNeeded(stickyId: sticky.id)
        return try store.fetch(id: sticky.id) ?? sticky
    }

    func updateContent(stickyId: String, html: String) throws {
        guard var sticky = try store.fetch(id: stickyId) else { return }
        sticky.contentHTML = html
        sticky.pendingPush = true
        sticky.updatedAt = Date()
        try store.upsert(sticky)
    }

    func push(stickyId: String) async throws {
        guard var sticky = try store.fetch(id: stickyId),
              let docId = sticky.googleDocId else { return }
        let attributed = HTMLNormalizer.attributedString(from: sticky.contentHTML)
        try await deps.pushBody(docId, attributed)
        sticky.lastSyncedHTML = sticky.contentHTML
        sticky.lastRevisionId = try await deps.fetchRevisionId(docId)
        sticky.lastSyncedAt = Date()
        sticky.pendingPush = false
        try store.upsert(sticky)
    }

    enum PullOutcome: Equatable {
        case unchanged           // remote revisionId matches local; nothing to do
        case updated             // remote was newer; local content replaced
        case conflict            // remote newer AND local had unsynced changes; local stashed
    }

    func pull(stickyId: String) async throws -> PullOutcome {
        guard var sticky = try store.fetch(id: stickyId),
              let docId = sticky.googleDocId else { return .unchanged }

        let remoteRevisionId = try await deps.fetchRevisionId(docId)
        if let remote = remoteRevisionId, remote == sticky.lastRevisionId {
            return .unchanged
        }

        let pulledHTML = try await deps.exportAsHTML(docId)
        let pulledAttr = HTMLNormalizer.attributedString(from: pulledHTML)
        let canonicalRemote = HTMLNormalizer.html(from: pulledAttr)

        let isLocalDirty = sticky.pendingPush && sticky.contentHTML != (sticky.lastSyncedHTML ?? "")
        let outcome: PullOutcome
        if isLocalDirty {
            sticky.conflictBackupHTML = sticky.contentHTML
            outcome = .conflict
        } else {
            outcome = .updated
        }
        sticky.contentHTML = canonicalRemote
        sticky.lastSyncedHTML = canonicalRemote
        sticky.lastRevisionId = remoteRevisionId
        sticky.lastSyncedAt = Date()
        sticky.pendingPush = false
        sticky.updatedAt = Date()
        try store.upsert(sticky)
        return outcome
    }

    func restoreBackup(stickyId: String) throws {
        guard var sticky = try store.fetch(id: stickyId),
              let backup = sticky.conflictBackupHTML else { return }
        sticky.contentHTML = backup
        sticky.conflictBackupHTML = nil
        sticky.pendingPush = true
        sticky.updatedAt = Date()
        try store.upsert(sticky)
    }

    func deleteSticky(id: String, alsoDeleteDoc: Bool) async throws {
        guard var sticky = try store.fetch(id: id) else { return }
        if alsoDeleteDoc, let docId = sticky.googleDocId {
            try await deps.deleteDoc(docId)
        }
        sticky.deletedLocally = true
        sticky.updatedAt = Date()
        try store.upsert(sticky)
    }
}

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
// Deferred (v2+): changes.list polling, exponential backoff.
@MainActor
final class SyncEngine {

    struct Dependencies {
        var createDoc: (_ title: String) async throws -> String                          // -> docId
        var exportAsHTML: (_ docId: String) async throws -> String
        var fetchRevisionId: (_ docId: String) async throws -> String?
        var pushBody: (_ docId: String, _ content: NSAttributedString) async throws -> Void
        var deleteDoc: (_ docId: String) async throws -> Void
        var ensureStickiesFolder: () async throws -> Void = {}
        var isTrashed: (_ docId: String) async throws -> Bool = { _ in false }
    }

    let store: StickyStore
    let deps: Dependencies

    // Per-sticky debounce timers for push-while-typing. Each new edit cancels
    // the prior pending task and starts a fresh one; blur/close cancels and
    // flushes immediately.
    private var debouncedPushTasks: [String: Task<Void, Never>] = [:]
    static let typingDebounce: Duration = .milliseconds(1500)

    init(store: StickyStore, deps: Dependencies) {
        self.store = store
        self.deps = deps
    }

    func schedulePush(stickyId: String) {
        debouncedPushTasks[stickyId]?.cancel()
        debouncedPushTasks[stickyId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.typingDebounce)
            guard !Task.isCancelled, let self else { return }
            self.debouncedPushTasks[stickyId] = nil
            try? await self.push(stickyId: stickyId)
        }
    }

    func cancelDebouncedPush(stickyId: String) {
        debouncedPushTasks[stickyId]?.cancel()
        debouncedPushTasks[stickyId] = nil
    }

    // MARK: - Operations

    // Creates a Sticky locally without touching the network or creating a
    // Drive Doc. The Doc is provisioned on first push - if the sticky never
    // gets any content, no Doc is ever created (keeps Drive tidy).
    func createLocalSticky(title: String = "") throws -> Sticky {
        var sticky = Sticky.makeNew(title: title)
        let frame = StickyPlacement.nextFrame()
        sticky.frameX = Double(frame.origin.x)
        sticky.frameY = Double(frame.origin.y)
        sticky.frameW = Double(frame.size.width)
        sticky.frameH = Double(frame.size.height)
        try store.upsert(sticky)
        return sticky
    }

    // Convenience for tests / scripted flows: creates local + provisions Doc
    // with the given title even if there's no content yet.
    func createSticky(title: String = "Untitled sticky") async throws -> Sticky {
        let sticky = try createLocalSticky(title: title)
        try await provisionDocIfNeeded(stickyId: sticky.id, fallbackTitle: title)
        return try store.fetch(id: sticky.id) ?? sticky
    }

    @MainActor
    private func provisionDocIfNeeded(stickyId: String, fallbackTitle: String) async throws {
        guard var sticky = try store.fetch(id: stickyId), sticky.googleDocId == nil else { return }
        try await deps.ensureStickiesFolder()
        let title = Self.titleForFirstSync(from: sticky.contentHTML, fallback: fallbackTitle)
        let docId = try await deps.createDoc(title)
        sticky.googleDocId = docId
        sticky.title = title
        sticky.lastRevisionId = try await deps.fetchRevisionId(docId)
        try store.upsert(sticky)
    }

    @MainActor
    private static func titleForFirstSync(from contentHTML: String, fallback: String) -> String {
        let plain = HTMLNormalizer.attributedString(from: contentHTML).string
        let firstLine = plain.components(separatedBy: .newlines).first ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if trimmed.count <= 50 { return trimmed }
            // Take as many whole words as fit in 50 chars (preserving order).
            var picked = ""
            for word in trimmed.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = picked.isEmpty ? String(word) : "\(picked) \(word)"
                if candidate.count > 50 { break }
                picked = candidate
            }
            if !picked.isEmpty { return picked }
        }
        if !fallback.isEmpty { return fallback }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Sticky \(f.string(from: Date()))"
    }

    func updateContent(stickyId: String, html: String) throws {
        guard var sticky = try store.fetch(id: stickyId) else { return }
        sticky.contentHTML = html
        sticky.pendingPush = true
        sticky.updatedAt = Date()
        try store.upsert(sticky)
        schedulePush(stickyId: stickyId)
    }

    func push(stickyId: String) async throws {
        do {
            try await pushInner(stickyId: stickyId)
        } catch {
            // Persist the failure so the sticky's status dot turns red with a
            // tooltip explaining what went wrong. pendingPush stays true so a
            // subsequent blur, debounce, or Sync Now retries automatically.
            try? recordPushError(stickyId: stickyId, error: error)
            throw error
        }
    }

    private func pushInner(stickyId: String) async throws {
        guard var sticky = try store.fetch(id: stickyId) else { return }
        // Skip stickies that have no real content yet - don't create a Doc
        // just for an empty note the user might still discard.
        let plain = HTMLNormalizer.attributedString(from: sticky.contentHTML).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return }

        // If the sticky has never been synced and has no doc, provision one.
        // But if it was previously synced and is now unlinked (Doc deleted in
        // Drive), don't auto-recreate - wait for an explicit user action.
        if sticky.googleDocId == nil {
            if sticky.lastSyncedAt != nil { return }   // unlinked, hold
            try await provisionDocIfNeeded(stickyId: stickyId, fallbackTitle: "")
            guard let refreshed = try store.fetch(id: stickyId) else { return }
            sticky = refreshed
        }
        guard let docId = sticky.googleDocId else { return }

        // Trashed Docs still accept writes via the API but are invisible to the
        // user in Drive. Detect this before pushing so we don't pollute trash
        // with new edits the user can't see.
        if (try? await deps.isTrashed(docId)) == true {
            try markUnlinked(&sticky)
            return
        }

        // Guard against silently overwriting remote edits: if the Doc's
        // revisionId advanced since our last sync, divert to pull() so the
        // conflict path runs (stash local into conflict_backup_html, accept
        // remote). After pull(), pendingPush is cleared so we don't continue.
        if sticky.lastRevisionId != nil {
            let remoteRevisionId: String?
            do {
                remoteRevisionId = try await deps.fetchRevisionId(docId)
            } catch let error as NSError where Self.isMissingDocError(error) {
                try markUnlinked(&sticky)
                return
            }
            if let remote = remoteRevisionId, remote != sticky.lastRevisionId {
                let outcome = try await pull(stickyId: stickyId)
                // If pull found a real remote change (or conflict), it has
                // taken over local state and cleared pendingPush; stop here.
                // Otherwise the revision bump was content-neutral and we
                // continue with our push using the refreshed lastRevisionId.
                guard outcome == .unchanged,
                      let refreshed = try store.fetch(id: stickyId) else { return }
                sticky = refreshed
                guard sticky.pendingPush else { return }
            }
        }

        let attributed = HTMLNormalizer.attributedString(from: sticky.contentHTML)
        do {
            try await deps.pushBody(docId, attributed)
            sticky.lastRevisionId = try await deps.fetchRevisionId(docId)
        } catch let error as NSError where Self.isMissingDocError(error) {
            try markUnlinked(&sticky)
            return
        }
        sticky.lastSyncedHTML = sticky.contentHTML
        sticky.lastSyncedAt = Date()
        sticky.pendingPush = false
        sticky.lastPushErrorMessage = nil
        sticky.lastPushErrorAt = nil
        try store.upsert(sticky)
    }

    private func recordPushError(stickyId: String, error: Error) throws {
        guard var sticky = try store.fetch(id: stickyId) else { return }
        sticky.lastPushErrorMessage = Self.userFacingMessage(for: error)
        sticky.lastPushErrorAt = Date()
        try store.upsert(sticky)
    }

    // User-invoked dismiss of an error banner. Keeps pendingPush=true so the
    // next blur, debounce, or Sync Now still retries; just stops nagging.
    func acknowledgePushError(stickyId: String) throws {
        guard var sticky = try store.fetch(id: stickyId) else { return }
        sticky.lastPushErrorMessage = nil
        sticky.lastPushErrorAt = nil
        try store.upsert(sticky)
    }

    private static func userFacingMessage(for error: Error) -> String {
        let ns = error as NSError
        // URLError surfaces network failures with reasonable localized strings;
        // our Drive/Docs client wraps HTTP errors in NSError with the response
        // body as localizedDescription, which is verbose but truthful.
        let raw = ns.localizedDescription
        if raw.isEmpty { return "Sync failed (\(ns.domain) \(ns.code))." }
        // Trim to a one-line tooltip-friendly length; full text still lives in
        // the NSLog stream for debugging.
        let max = 200
        return raw.count <= max ? raw : String(raw.prefix(max)) + "…"
    }

    private static func isMissingDocError(_ error: NSError) -> Bool {
        error.code == 404 || error.code == 410
    }

    private func markUnlinked(_ sticky: inout Sticky) throws {
        sticky.googleDocId = nil
        sticky.lastRevisionId = nil
        sticky.pendingPush = false
        sticky.updatedAt = Date()
        try store.upsert(sticky)
    }

    // User-initiated recovery from an unlinked state: forces a fresh Doc
    // to be provisioned with current content.
    func recreateDoc(stickyId: String) async throws {
        guard var sticky = try store.fetch(id: stickyId) else { return }
        sticky.lastSyncedAt = nil   // clear the "was-ever-synced" sentinel so push will provision
        sticky.lastSyncedHTML = nil
        sticky.pendingPush = true
        try store.upsert(sticky)
        try await push(stickyId: stickyId)
    }

    enum PullOutcome: Equatable {
        case unchanged           // remote revisionId matches local; nothing to do
        case updated             // remote was newer; local content replaced
        case conflict            // remote newer AND local had unsynced changes; local stashed
    }

    func pull(stickyId: String) async throws -> PullOutcome {
        guard var sticky = try store.fetch(id: stickyId),
              let docId = sticky.googleDocId else { return .unchanged }

        let remoteRevisionId: String?
        do {
            remoteRevisionId = try await deps.fetchRevisionId(docId)
        } catch let error as NSError where Self.isMissingDocError(error) {
            try markUnlinked(&sticky)
            return .unchanged
        }
        if let remote = remoteRevisionId, remote == sticky.lastRevisionId {
            return .unchanged
        }

        let pulledHTML = try await deps.exportAsHTML(docId)
        let pulledAttr = HTMLNormalizer.attributedString(from: pulledHTML)
        let canonicalRemote = HTMLNormalizer.html(from: pulledAttr)

        // Google Docs advances revisionId on events that don't change content
        // (e.g. opening the Doc in a browser creates a viewing revision). If
        // the remote canonical HTML matches what we last synced, this is a
        // no-op bump: track the new revisionId and report unchanged so any
        // pending local push can proceed without a spurious conflict.
        if canonicalRemote == (sticky.lastSyncedHTML ?? "") {
            sticky.lastRevisionId = remoteRevisionId
            try store.upsert(sticky)
            return .unchanged
        }

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

    func discardBackup(stickyId: String) throws {
        guard var sticky = try store.fetch(id: stickyId),
              sticky.conflictBackupHTML != nil else { return }
        sticky.conflictBackupHTML = nil
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

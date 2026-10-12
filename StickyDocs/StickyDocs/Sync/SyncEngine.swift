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

// Thrown by Dependencies.pushBody when the Doc changed in Drive since the
// revision the engine last synced; the engine diverts to pull.
struct RemoteRevisionChangedError: Error {}

@MainActor
final class SyncEngine {

    // Posted synchronously (main actor) whenever the engine replaces a
    // sticky's contentHTML with text the editor didn't type: a pull that
    // brought in remote content, or restoring a conflict backup. A focused
    // editor otherwise ignores store updates, so without this the next
    // keystroke would write its stale text back over the new content.
    // userInfo: stickyIdKey, htmlKey.
    nonisolated static let contentReplacedExternally = Notification.Name("SyncEngine.contentReplacedExternally")
    nonisolated static let stickyIdKey = "stickyId"
    nonisolated static let htmlKey = "html"

    private func postContentReplaced(stickyId: String, html: String) {
        NotificationCenter.default.post(
            name: Self.contentReplacedExternally,
            object: self,
            userInfo: [Self.stickyIdKey: stickyId, Self.htmlKey: html]
        )
    }

    // A tagged Doc in Drive, as seen by discovery. Timestamps are optional
    // because Drive may omit them and older fakes don't supply them.
    struct RemoteSticky {
        let id: String
        let name: String
        var modifiedTime: Date?
        var createdTime: Date?

        init(id: String, name: String, modifiedTime: Date? = nil, createdTime: Date? = nil) {
            self.id = id
            self.name = name
            self.modifiedTime = modifiedTime
            self.createdTime = createdTime
        }
    }

    struct Dependencies {
        var createDoc: (_ title: String) async throws -> String                          // -> docId
        var exportAsHTML: (_ docId: String) async throws -> String
        var fetchRevisionId: (_ docId: String) async throws -> String?
        // Replaces the Doc body; returns the revisionId of the write. Must
        // throw RemoteRevisionChangedError, without writing, if the Doc is
        // no longer at expectedRevisionId (when non-nil).
        var pushBody: (_ docId: String, _ content: NSAttributedString, _ expectedRevisionId: String?) async throws -> String?
        var deleteDoc: (_ docId: String) async throws -> Void
        var ensureStickiesFolder: () async throws -> Void = {}
        var isTrashed: (_ docId: String) async throws -> Bool = { _ in false }
        // Cross-machine restore: returns (docId, title, Drive timestamps) for
        // every Doc this OAuth client previously tagged with stickydocs=v1.
        // The timestamps let imported stickies keep their real edit recency
        // instead of collapsing to import order in the All Stickies list.
        // Default returns empty so unit tests don't need to mock discovery.
        var listTaggedStickies: () async throws -> [RemoteSticky] = { [] }
    }

    let store: StickyStore
    let deps: Dependencies

    // Per-sticky debounce timers for push-while-typing. Each new edit cancels
    // the prior pending task and starts a fresh one; blur/close cancels and
    // flushes immediately.
    private var debouncedPushTasks: [String: Task<Void, Never>] = [:]
    static let typingDebounce: Duration = .milliseconds(1500)

    // Per-sticky serialization for push() and pull(). Without this, a debounced
    // push that is already mid-await (e.g. inside createDoc) can race with a
    // blur/close flush: both read googleDocId == nil and both call createDoc,
    // producing two Docs in Drive while only one id wins in the store. Chaining
    // each operation through the previous in-flight task forces them to run
    // sequentially.
    //
    // Serialization does NOT protect against updateContent(), which runs
    // synchronously on every keystroke while a push/pull is awaiting the
    // network. Any write after an await must therefore re-fetch the row and
    // touch only sync bookkeeping, never write back a contentHTML read before
    // the await — otherwise text typed mid-sync is silently reverted.
    private var syncInFlight: [String: Task<Void, Never>] = [:]

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
            // An earlier push that was in flight when this edit happened may
            // already have carried it to Drive.
            guard (try? self.store.fetch(id: stickyId))?.pendingPush == true else { return }
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
        guard let sticky = try store.fetch(id: stickyId), sticky.googleDocId == nil else { return }
        try await deps.ensureStickiesFolder()
        let title = Self.titleForFirstSync(from: sticky.contentHTML, fallback: fallbackTitle)
        let docId = try await deps.createDoc(title)
        let revisionId = try await deps.fetchRevisionId(docId)
        // Re-fetch: the user may have kept typing while the Doc was created.
        guard var current = try store.fetch(id: stickyId) else { return }
        current.googleDocId = docId
        current.title = title
        current.lastRevisionId = revisionId
        try store.upsert(current)
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

    // Cross-machine restore: pull in every Doc this OAuth client previously
    // tagged that isn't already in the local store. Idempotent — second call
    // is a no-op once everything is imported. Imported stickies land with
    // isOpen=false so a fresh install doesn't spawn N floating windows; the
    // user can selectively reopen them from All Stickies.
    //
    // `onPendingImports` is invoked once, right after the cheap list call
    // resolves and before the slow per-doc fetches start. AppController uses
    // it to surface the All Stickies panel immediately on a fresh install so
    // the user sees something happening (stickies then trickle into the panel
    // via ValueObservation as each upsert completes) instead of staring at
    // the dock for several seconds.
    func discoverRemoteStickies(
        onPendingImports: ((Int) -> Void)? = nil
    ) async throws -> Int {
        let docs = try await deps.listTaggedStickies()
        let toImport: [RemoteSticky] = try docs.compactMap { doc in
            try store.fetchByDocId(doc.id) == nil ? doc : nil
        }
        onPendingImports?(toImport.count)

        var imported = 0
        for doc in toImport {
            let html = try await deps.exportAsHTML(doc.id)
            let canonical = HTMLNormalizer.html(from: HTMLNormalizer.attributedString(from: html))
            let revisionId = try? await deps.fetchRevisionId(doc.id)
            let frame = StickyPlacement.nextFrame()
            let now = Date()
            let sticky = Sticky(
                id: UUID().uuidString,
                googleDocId: doc.id,
                title: doc.name,
                contentHTML: canonical,
                lastSyncedHTML: canonical,
                conflictBackupHTML: nil,
                lastRevisionId: revisionId,
                frameX: Double(frame.origin.x),
                frameY: Double(frame.origin.y),
                frameW: Double(frame.size.width),
                frameH: Double(frame.size.height),
                color: "yellow",
                collapsed: false,
                createdAt: doc.createdTime ?? now,
                // Keep Drive's modification time so the All Stickies list,
                // which sorts by updatedAt, reflects real edit recency rather
                // than the arbitrary order this import loop happened to run in.
                updatedAt: doc.modifiedTime ?? now,
                lastSyncedAt: now,
                pendingPush: false,
                deletedLocally: false,
                isOpen: false,
                lastPushErrorMessage: nil,
                lastPushErrorAt: nil
            )
            try store.upsert(sticky)
            imported += 1
        }
        return imported
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
        try await serialized(stickyId: stickyId) {
            try await self.pushSerialized(stickyId: stickyId)
        }
    }

    // Runs `operation` after any push/pull already in flight for this sticky.
    private func serialized<T: Sendable>(
        stickyId: String,
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let previous = syncInFlight[stickyId]
        let task = Task { @MainActor () -> Result<T, Error> in
            _ = await previous?.value
            do { return .success(try await operation()) } catch { return .failure(error) }
        }
        syncInFlight[stickyId] = Task { _ = await task.value }
        return try await task.value.get()
    }

    private func pushSerialized(stickyId: String) async throws {
        do {
            try await pushInner(stickyId: stickyId)
        } catch {
            // Persist the failure so the sticky's status dot turns red with a
            // banner explaining what went wrong. pendingPush stays true so a
            // subsequent blur, debounce, or Sync Now retries automatically.
            //
            // If Google rejected our token with a 401 (grant revoked while the
            // cached access token was still within its lifetime, so refresh
            // never ran), treat it as a sign-out: clear the keychain entry so
            // the menu bar flips to "Sign In with Google..." and persist the
            // canonical "Not signed in" message so the banner switches to the
            // blue Sign In variant.
            if Self.isAuthError(error) {
                try? AuthService.shared.signOut()
                try? recordPushError(stickyId: stickyId, error: Self.notSignedInError)
            } else {
                try? recordPushError(stickyId: stickyId, error: error)
            }
            throw error
        }
    }

    private static func isAuthError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == "GoogleDocs" || ns.domain == "GoogleDrive" {
            return ns.code == 401 || ns.code == 403
        }
        // AuthService.AuthError.notSignedIn surfaces as the same NSError shape
        // after bridging via localizedDescription; matching by message keeps the
        // engine free of an AuthService dependency for this comparison.
        return ns.localizedDescription == "Not signed in"
    }

    private static let notSignedInError = NSError(
        domain: "StickyDocsAuth",
        code: 401,
        userInfo: [NSLocalizedDescriptionKey: "Not signed in"]
    )

    private func pushInner(stickyId: String) async throws {
        guard var sticky = try store.fetch(id: stickyId), !sticky.deletedLocally else { return }

        // If the sticky has never been synced and has no doc, provision one.
        // But if it was previously synced and is now unlinked (Doc deleted in
        // Drive), don't auto-recreate - wait for an explicit user action.
        if sticky.googleDocId == nil {
            if sticky.lastSyncedAt != nil { return }   // unlinked, hold
            // Don't create a Doc just for an empty note the user might still
            // discard. (Only applies before provisioning: clearing a sticky
            // that already has a Doc must still push the empty body.)
            let plain = HTMLNormalizer.attributedString(from: sticky.contentHTML).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plain.isEmpty else { return }
            try await provisionDocIfNeeded(stickyId: stickyId, fallbackTitle: "")
            guard let refreshed = try store.fetch(id: stickyId) else { return }
            sticky = refreshed
        }
        guard let docId = sticky.googleDocId else { return }

        // Trashed Docs still accept writes via the API but are invisible to the
        // user in Drive. Detect this before pushing so we don't pollute trash
        // with new edits the user can't see.
        if (try? await deps.isTrashed(docId)) == true {
            try markUnlinked(stickyId: stickyId)
            return
        }

        // pushBody refuses to write if the Doc has moved past lastRevisionId,
        // so remote edits are never silently overwritten. On refusal, divert
        // to pull: a real remote change (or conflict) takes over local state
        // and clears pendingPush; a content-neutral revision bump refreshes
        // lastRevisionId and we retry once.
        for _ in 0..<2 {
            let pushedHTML = sticky.contentHTML
            let attributed = HTMLNormalizer.attributedString(from: pushedHTML)
            let newRevisionId: String?
            do {
                newRevisionId = try await deps.pushBody(docId, attributed, sticky.lastRevisionId)
            } catch is RemoteRevisionChangedError {
                // pullInner, not pull: we're already inside the serialized
                // chain, and pull() would wait on ourselves.
                let outcome = try await pullInner(stickyId: stickyId)
                guard outcome == .unchanged,
                      let refreshed = try store.fetch(id: stickyId),
                      refreshed.pendingPush,
                      refreshed.googleDocId == docId else { return }
                sticky = refreshed
                continue
            } catch let error as NSError where Self.isMissingDocError(error) {
                try markUnlinked(stickyId: stickyId)
                return
            }
            // Re-fetch: edits made while the push was in flight must survive,
            // and stay pending so the debounce they scheduled pushes them next.
            guard var current = try store.fetch(id: stickyId) else { return }
            current.lastRevisionId = newRevisionId
            current.lastSyncedHTML = pushedHTML
            current.lastSyncedAt = Date()
            current.pendingPush = current.contentHTML != pushedHTML
            current.lastPushErrorMessage = nil
            current.lastPushErrorAt = nil
            try store.upsert(current)
            return
        }
        // Still racing remote edits after a retry; pendingPush stays true and
        // the next blur, debounce or Sync Now tries again.
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

    private func markUnlinked(stickyId: String) throws {
        guard var sticky = try store.fetch(id: stickyId) else { return }
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
        try await serialized(stickyId: stickyId) {
            try await self.pullInner(stickyId: stickyId)
        }
    }

    private func pullInner(stickyId: String) async throws -> PullOutcome {
        guard let snapshot = try store.fetch(id: stickyId),
              let docId = snapshot.googleDocId else { return .unchanged }

        let remoteRevisionId: String?
        do {
            remoteRevisionId = try await deps.fetchRevisionId(docId)
        } catch let error as NSError where Self.isMissingDocError(error) {
            try markUnlinked(stickyId: stickyId)
            return .unchanged
        }
        if let remote = remoteRevisionId, remote == snapshot.lastRevisionId {
            return .unchanged
        }

        let pulledHTML = try await deps.exportAsHTML(docId)
        let pulledAttr = HTMLNormalizer.attributedString(from: pulledHTML)
        let canonicalRemote = HTMLNormalizer.html(from: pulledAttr)

        // Re-fetch so the dirty check and conflict backup see edits typed
        // while the export was in flight.
        guard var sticky = try store.fetch(id: stickyId) else { return .unchanged }

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
        postContentReplaced(stickyId: stickyId, html: canonicalRemote)
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
        postContentReplaced(stickyId: stickyId, html: backup)
    }

    func discardBackup(stickyId: String) throws {
        guard var sticky = try store.fetch(id: stickyId),
              sticky.conflictBackupHTML != nil else { return }
        sticky.conflictBackupHTML = nil
        sticky.updatedAt = Date()
        try store.upsert(sticky)
    }

    func deleteSticky(id: String, alsoDeleteDoc: Bool) async throws {
        // Drop the pending debounce and wait for any in-flight push, so a
        // push can't provision (or write to) a Doc after the delete.
        cancelDebouncedPush(stickyId: id)
        try await serialized(stickyId: id) {
            try await self.deleteStickyInner(id: id, alsoDeleteDoc: alsoDeleteDoc)
        }
    }

    private func deleteStickyInner(id: String, alsoDeleteDoc: Bool) async throws {
        guard let snapshot = try store.fetch(id: id) else { return }
        if alsoDeleteDoc, let docId = snapshot.googleDocId {
            try await deps.deleteDoc(docId)
        }
        guard var sticky = try store.fetch(id: id) else { return }
        sticky.deletedLocally = true
        sticky.updatedAt = Date()
        try store.upsert(sticky)
    }
}

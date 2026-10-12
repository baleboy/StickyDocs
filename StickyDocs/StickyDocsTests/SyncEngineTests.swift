import Testing
import Foundation
import AppKit
@testable import StickyDocs

@MainActor
struct SyncEngineTests {

    @MainActor private final class FakeBackend {
        var nextDocId: String = "doc-1"
        var docs: [String: String] = [:]   // docId -> HTML body (canonical HTML for simplicity)
        var revisions: [String: String] = [:]
        var deleted: Set<String> = []
        var pushCount = 0
        // Run mid-request to simulate the user typing while a network call
        // is in flight.
        var duringCreateDoc: (() throws -> Void)?
        var duringPushBody: (() throws -> Void)?
        var duringExport: (() throws -> Void)?

        func deps() -> SyncEngine.Dependencies {
            SyncEngine.Dependencies(
                createDoc: { _ in
                    try self.duringCreateDoc?()
                    let id = self.nextDocId
                    self.docs[id] = ""
                    self.revisions[id] = "rev-0"
                    return id
                },
                exportAsHTML: { docId in
                    try self.duringExport?()
                    return self.docs[docId] ?? ""
                },
                fetchRevisionId: { docId in self.revisions[docId] },
                pushBody: { docId, attributed, expectedRevisionId in
                    if let expectedRevisionId, expectedRevisionId != self.revisions[docId] {
                        throw RemoteRevisionChangedError()
                    }
                    self.pushCount += 1
                    self.docs[docId] = HTMLNormalizer.html(from: attributed)
                    self.bumpRevision(docId)
                    let writtenRevision = self.revisions[docId]
                    try self.duringPushBody?()
                    return writtenRevision
                },
                deleteDoc: { docId in self.deleted.insert(docId) }
            )
        }

        func remoteEdit(docId: String, html: String) {
            docs[docId] = html
            bumpRevision(docId)
        }

        func bumpRevision(_ docId: String) {
            let n = (revisions[docId]?.split(separator: "-").last.flatMap { Int($0) } ?? 0) + 1
            revisions[docId] = "rev-\(n)"
        }
    }

    private func makeFixture() throws -> (StickyStore, FakeBackend, SyncEngine) {
        let store = try StickyStore.inMemory()
        let backend = FakeBackend()
        let engine = SyncEngine(store: store, deps: backend.deps())
        return (store, backend, engine)
    }

    @Test func createStickyCreatesLocalRowAndDoc() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky(title: "test")
        #expect(sticky.googleDocId == "doc-1")
        #expect(sticky.lastRevisionId == "rev-0")
        #expect(backend.docs["doc-1"] == "")
        #expect(try store.fetch(id: sticky.id)?.googleDocId == "doc-1")
    }

    @Test func updateContentMarksPending() async throws {
        let (store, _, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>edited</p>")
        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.contentHTML == "<p>edited</p>")
        #expect(loaded.pendingPush == true)
        #expect(loaded.lastSyncedHTML == nil)
    }

    @Test func pushSendsContentAndClearsDirty() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>edited</p>")
        try await engine.push(stickyId: sticky.id)

        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.pendingPush == false)
        #expect(loaded.lastSyncedHTML == "<p>edited</p>")
        #expect(loaded.lastRevisionId == "rev-1")
        #expect(backend.pushCount == 1)
        #expect(backend.docs["doc-1"] == "<p>edited</p>")
    }

    @Test func pullUnchangedWhenRevisionMatches() async throws {
        let (_, _, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        let outcome = try await engine.pull(stickyId: sticky.id)
        #expect(outcome == .unchanged)
    }

    @Test func pullUpdatesWhenRemoteAdvancedAndLocalClean() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        backend.remoteEdit(docId: "doc-1", html: "<p>from web</p>")

        let outcome = try await engine.pull(stickyId: sticky.id)
        #expect(outcome == .updated)

        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.contentHTML == "<p>from web</p>")
        #expect(loaded.lastRevisionId == "rev-1")
        #expect(loaded.conflictBackupHTML == nil)
    }

    @Test func pullConflictStashesLocalAndAcceptsRemote() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>my edit</p>")
        backend.remoteEdit(docId: "doc-1", html: "<p>their edit</p>")

        let outcome = try await engine.pull(stickyId: sticky.id)
        #expect(outcome == .conflict)

        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.contentHTML == "<p>their edit</p>")
        #expect(loaded.conflictBackupHTML == "<p>my edit</p>")
        #expect(loaded.pendingPush == false)
    }

    @Test func restoreBackupSwapsContentAndMarksPending() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>my edit</p>")
        backend.remoteEdit(docId: "doc-1", html: "<p>their edit</p>")
        _ = try await engine.pull(stickyId: sticky.id)

        try engine.restoreBackup(stickyId: sticky.id)
        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.contentHTML == "<p>my edit</p>")
        #expect(loaded.conflictBackupHTML == nil)
        #expect(loaded.pendingPush == true)
    }

    @Test func pushDivertsToPullWhenRemoteAdvanced() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        // Establish a baseline synced state.
        try engine.updateContent(stickyId: sticky.id, html: "<p>v1</p>")
        try await engine.push(stickyId: sticky.id)
        let pushesAfterBaseline = backend.pushCount

        // Remote advances and we make a local edit without pulling first.
        backend.remoteEdit(docId: "doc-1", html: "<p>their edit</p>")
        try engine.updateContent(stickyId: sticky.id, html: "<p>my edit</p>")

        try await engine.push(stickyId: sticky.id)

        // Push must NOT have written the local edit; it should have diverted
        // to pull which stashes local and accepts remote.
        #expect(backend.pushCount == pushesAfterBaseline)
        #expect(backend.docs["doc-1"] == "<p>their edit</p>")
        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.contentHTML == "<p>their edit</p>")
        #expect(loaded.conflictBackupHTML == "<p>my edit</p>")
        #expect(loaded.pendingPush == false)
    }

    @Test func discardBackupClearsBackupWithoutChangingContent() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>my edit</p>")
        backend.remoteEdit(docId: "doc-1", html: "<p>their edit</p>")
        _ = try await engine.pull(stickyId: sticky.id)

        try engine.discardBackup(stickyId: sticky.id)
        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.contentHTML == "<p>their edit</p>")
        #expect(loaded.conflictBackupHTML == nil)
        #expect(loaded.pendingPush == false)
    }

    @Test func deleteWithoutDocOnlySoftDeletes() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try await engine.deleteSticky(id: sticky.id, alsoDeleteDoc: false)
        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.deletedLocally == true)
        #expect(backend.deleted.isEmpty)
    }

    @Test func deleteWithDocTrashesDriveFile() async throws {
        let (_, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try await engine.deleteSticky(id: sticky.id, alsoDeleteDoc: true)
        #expect(backend.deleted.contains("doc-1"))
    }

    // Imported stickies must keep Drive's modification time, otherwise the
    // All Stickies list (ordered by updatedAt) shows them in import order.
    @Test func discoveryPreservesDriveModifiedTime() async throws {
        let store = try StickyStore.inMemory()
        let backend = FakeBackend()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        var deps = backend.deps()
        backend.docs = ["doc-old": "<p>old</p>", "doc-new": "<p>new</p>"]
        deps.listTaggedStickies = {
            [
                // Deliberately listed newest-first so import order differs
                // from the expected sort order.
                SyncEngine.RemoteSticky(id: "doc-new", name: "New", modifiedTime: newer, createdTime: older),
                SyncEngine.RemoteSticky(id: "doc-old", name: "Old", modifiedTime: older, createdTime: older)
            ]
        }
        let engine = SyncEngine(store: store, deps: deps)

        let imported = try await engine.discoverRemoteStickies()
        #expect(imported == 2)

        let all = try store.allActive()
        #expect(all.map(\.title) == ["New", "Old"])
        #expect(all[0].updatedAt == newer)
        #expect(all[1].updatedAt == older)
        #expect(all[1].createdAt == older)
    }

    // Drive can omit timestamps; imports must still land with a usable date.
    @Test func discoveryFallsBackToNowWhenDriveOmitsTimestamps() async throws {
        let store = try StickyStore.inMemory()
        let backend = FakeBackend()
        var deps = backend.deps()
        backend.docs = ["doc-x": "<p>x</p>"]
        deps.listTaggedStickies = { [SyncEngine.RemoteSticky(id: "doc-x", name: "X")] }
        let engine = SyncEngine(store: store, deps: deps)

        let before = Date()
        _ = try await engine.discoverRemoteStickies()
        let loaded = try #require(try store.fetchByDocId("doc-x"))
        #expect(loaded.updatedAt >= before)
    }

    // MARK: - Edits made while a sync is in flight

    @Test func editDuringPushIsNotLost() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>hello</p>")
        backend.duringPushBody = {
            backend.duringPushBody = nil
            try engine.updateContent(stickyId: sticky.id, html: "<p>hello world</p>")
        }

        try await engine.push(stickyId: sticky.id)

        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.contentHTML == "<p>hello world</p>")
        #expect(loaded.lastSyncedHTML == "<p>hello</p>")
        #expect(loaded.pendingPush == true)

        try await engine.push(stickyId: sticky.id)
        #expect(backend.docs["doc-1"] == "<p>hello world</p>")
        #expect(try store.fetch(id: sticky.id)?.pendingPush == false)
    }

    @Test func editDuringDocProvisioningIsNotLost() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try engine.createLocalSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>hello</p>")
        backend.duringCreateDoc = {
            backend.duringCreateDoc = nil
            try engine.updateContent(stickyId: sticky.id, html: "<p>hello world</p>")
        }

        try await engine.push(stickyId: sticky.id)

        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.googleDocId == "doc-1")
        #expect(loaded.contentHTML == "<p>hello world</p>")
        #expect(loaded.pendingPush == false)
        #expect(backend.docs["doc-1"] == "<p>hello world</p>")
    }

    @Test func editDuringPullIsStashedAsConflict() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        backend.remoteEdit(docId: "doc-1", html: "<p>their edit</p>")
        backend.duringExport = {
            backend.duringExport = nil
            try engine.updateContent(stickyId: sticky.id, html: "<p>my edit</p>")
        }

        let outcome = try await engine.pull(stickyId: sticky.id)

        #expect(outcome == .conflict)
        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.contentHTML == "<p>their edit</p>")
        #expect(loaded.conflictBackupHTML == "<p>my edit</p>")
    }

    // MARK: - Push/pull edge cases

    @Test func clearingSyncedStickyPushesEmptyBody() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>hello</p>")
        try await engine.push(stickyId: sticky.id)

        try engine.updateContent(stickyId: sticky.id, html: "")
        try await engine.push(stickyId: sticky.id)

        #expect(backend.docs["doc-1"] == "")
        #expect(try store.fetch(id: sticky.id)?.pendingPush == false)
    }

    @Test func emptyUnprovisionedStickyStillCreatesNoDoc() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try engine.createLocalSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>   </p>")
        try await engine.push(stickyId: sticky.id)
        #expect(backend.docs.isEmpty)
        #expect(try store.fetch(id: sticky.id)?.googleDocId == nil)
    }

    @Test func contentNeutralRevisionBumpStillPushes() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>v1</p>")
        try await engine.push(stickyId: sticky.id)

        backend.bumpRevision("doc-1")   // e.g. Doc opened in a browser
        try engine.updateContent(stickyId: sticky.id, html: "<p>v2</p>")
        try await engine.push(stickyId: sticky.id)

        #expect(backend.docs["doc-1"] == "<p>v2</p>")
        let loaded = try #require(try store.fetch(id: sticky.id))
        #expect(loaded.pendingPush == false)
        #expect(loaded.conflictBackupHTML == nil)
    }

    @Test func remoteEditRightAfterOurWriteIsStillPulled() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>mine</p>")
        backend.duringPushBody = {
            backend.duringPushBody = nil
            backend.remoteEdit(docId: "doc-1", html: "<p>theirs</p>")
        }
        try await engine.push(stickyId: sticky.id)

        // We must have recorded the revision of OUR write, not theirs.
        let outcome = try await engine.pull(stickyId: sticky.id)
        #expect(outcome == .updated)
        #expect(try store.fetch(id: sticky.id)?.contentHTML == "<p>theirs</p>")
    }

    @Test func deletedStickyIsNeverPushed() async throws {
        let (store, backend, engine) = try makeFixture()
        let sticky = try engine.createLocalSticky()
        try engine.updateContent(stickyId: sticky.id, html: "<p>typed then trashed</p>")
        try await engine.deleteSticky(id: sticky.id, alsoDeleteDoc: false)

        #expect(try store.pendingPushes().isEmpty)
        try await engine.push(stickyId: sticky.id)
        #expect(backend.docs.isEmpty)
        #expect(backend.pushCount == 0)
    }

    @Test func pullPostsExternalContentReplacement() async throws {
        let (_, backend, engine) = try makeFixture()
        let sticky = try await engine.createSticky()
        backend.remoteEdit(docId: "doc-1", html: "<p>from web</p>")

        var received: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: SyncEngine.contentReplacedExternally, object: engine, queue: nil
        ) { note in
            if note.userInfo?[SyncEngine.stickyIdKey] as? String == sticky.id,
               let html = note.userInfo?[SyncEngine.htmlKey] as? String {
                received.append(html)
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try await engine.pull(stickyId: sticky.id)
        #expect(received == ["<p>from web</p>"])
    }
}

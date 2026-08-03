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

        func deps() -> SyncEngine.Dependencies {
            SyncEngine.Dependencies(
                createDoc: { _ in
                    let id = self.nextDocId
                    self.docs[id] = ""
                    self.revisions[id] = "rev-0"
                    return id
                },
                exportAsHTML: { docId in self.docs[docId] ?? "" },
                fetchRevisionId: { docId in self.revisions[docId] },
                pushBody: { docId, attributed in
                    self.pushCount += 1
                    self.docs[docId] = HTMLNormalizer.html(from: attributed)
                    self.bumpRevision(docId)
                },
                deleteDoc: { docId in self.deleted.insert(docId) }
            )
        }

        func remoteEdit(docId: String, html: String) {
            docs[docId] = html
            bumpRevision(docId)
        }

        private func bumpRevision(_ docId: String) {
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
}

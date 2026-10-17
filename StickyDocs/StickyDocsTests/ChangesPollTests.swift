import Testing
import Foundation
import AppKit
@testable import StickyDocs

@MainActor
struct ChangesPollTests {

    // Drive stand-in with a changes feed: the page token is an index into
    // `log`, and a token past the end (or `expireTokens`) is rejected the way
    // Drive rejects an expired one.
    @MainActor private final class FakeDrive {
        var docs: [String: String] = [:]
        var revisions: [String: String] = [:]
        var log: [SyncEngine.RemoteChange] = []
        var tagged: [SyncEngine.RemoteSticky] = []
        var pageSize = 100
        var expireTokens = false
        var exportCount = 0
        var failExport = false

        func deps() -> SyncEngine.Dependencies {
            var deps = SyncEngine.Dependencies(
                createDoc: { _ in "unused" },
                exportAsHTML: { docId in
                    if self.failExport { throw URLError(.notConnectedToInternet) }
                    self.exportCount += 1
                    return self.docs[docId] ?? ""
                },
                fetchRevisionId: { self.revisions[$0] },
                pushBody: { _, _, _ in nil },
                deleteDoc: { _ in }
            )
            deps.listTaggedStickies = { self.tagged }
            deps.fetchStartPageToken = { "\(self.log.count)" }
            deps.listChanges = { token in
                guard !self.expireTokens, let start = Int(token), start <= self.log.count else {
                    throw NSError(domain: "GoogleDrive", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid pageToken"])
                }
                let end = min(start + self.pageSize, self.log.count)
                let changes = Array(self.log[start..<end])
                return end < self.log.count
                    ? SyncEngine.ChangesPage(changes: changes, nextPageToken: "\(end)", newStartPageToken: nil)
                    : SyncEngine.ChangesPage(changes: changes, nextPageToken: nil, newStartPageToken: "\(end)")
            }
            return deps
        }

        func remoteEdit(docId: String, html: String) {
            docs[docId] = html
            let n = (revisions[docId]?.split(separator: "-").last.flatMap { Int($0) } ?? 0) + 1
            revisions[docId] = "rev-\(n)"
            log.append(SyncEngine.RemoteChange(fileId: docId, isTaggedSticky: true))
        }
    }

    private func makeFixture() throws -> (StickyStore, FakeDrive, SyncEngine) {
        let store = try StickyStore.inMemory()
        let drive = FakeDrive()
        return (store, drive, SyncEngine(store: store, deps: drive.deps()))
    }

    // A synced sticky linked to `docId`, matching the fake's current state.
    private func syncedSticky(_ store: StickyStore, _ drive: FakeDrive, docId: String, html: String) throws -> Sticky {
        drive.docs[docId] = html
        drive.revisions[docId] = "rev-0"
        var sticky = Sticky.makeNew(title: docId)
        sticky.googleDocId = docId
        sticky.contentHTML = html
        sticky.lastSyncedHTML = html
        sticky.lastRevisionId = "rev-0"
        sticky.lastSyncedAt = Date()
        try store.upsert(sticky)
        return sticky
    }

    private func token(_ store: StickyStore) throws -> String? {
        try store.getAppState(key: SyncEngine.changesPageTokenKey)
    }

    @Test func firstPollOnlyRecordsStartToken() async throws {
        let (store, drive, engine) = try makeFixture()
        _ = try syncedSticky(store, drive, docId: "doc-a", html: "<p>a</p>")
        drive.remoteEdit(docId: "doc-a", html: "<p>before baseline</p>")

        let result = try await engine.pollRemoteChanges()

        #expect(result == SyncEngine.PollResult())
        #expect(try token(store) == "1")
        #expect(drive.exportCount == 0)
    }

    @Test func pollPullsOnlyChangedStickies() async throws {
        let (store, drive, engine) = try makeFixture()
        let a = try syncedSticky(store, drive, docId: "doc-a", html: "<p>a</p>")
        let b = try syncedSticky(store, drive, docId: "doc-b", html: "<p>b</p>")
        _ = try await engine.pollRemoteChanges()

        let edited = HTMLNormalizer.html(from: HTMLNormalizer.attributedString(from: "<p>edited on phone</p>"))
        drive.remoteEdit(docId: "doc-a", html: edited)
        let result = try await engine.pollRemoteChanges()

        #expect(result.pulled == [a.id: .updated])
        #expect(try store.fetch(id: a.id)?.contentHTML == edited)
        #expect(try store.fetch(id: b.id)?.contentHTML == "<p>b</p>")
        #expect(try token(store) == "1")

        // Nothing new: no pulls.
        let again = try await engine.pollRemoteChanges()
        #expect(again.pulled.isEmpty)
    }

    @Test func pollFollowsPagesAndDedupesFiles() async throws {
        let (store, drive, engine) = try makeFixture()
        let a = try syncedSticky(store, drive, docId: "doc-a", html: "<p>a</p>")
        _ = try await engine.pollRemoteChanges()
        drive.pageSize = 1
        drive.remoteEdit(docId: "doc-a", html: "<p>one</p>")
        drive.remoteEdit(docId: "doc-a", html: "<p>two</p>")
        drive.remoteEdit(docId: "doc-a", html: "<p>three</p>")

        let result = try await engine.pollRemoteChanges()

        #expect(result.pulled == [a.id: .updated])
        #expect(drive.exportCount == 1)
        #expect(try token(store) == "3")
    }

    @Test func pollImportsUnknownTaggedDoc() async throws {
        let (store, drive, engine) = try makeFixture()
        _ = try await engine.pollRemoteChanges()
        drive.docs["doc-new"] = "<p>from the other Mac</p>"
        drive.tagged = [SyncEngine.RemoteSticky(id: "doc-new", name: "New")]
        drive.log.append(SyncEngine.RemoteChange(fileId: "doc-new", isTaggedSticky: true))
        // Untagged files we can see (e.g. the Stickies folder) don't trigger discovery.
        drive.log.append(SyncEngine.RemoteChange(fileId: "folder"))

        let result = try await engine.pollRemoteChanges()

        #expect(result.imported == 1)
        #expect(try store.fetchByDocId("doc-new") != nil)
    }

    @Test func failedPullKeepsTokenForRetry() async throws {
        let (store, drive, engine) = try makeFixture()
        let a = try syncedSticky(store, drive, docId: "doc-a", html: "<p>a</p>")
        _ = try await engine.pollRemoteChanges()
        drive.remoteEdit(docId: "doc-a", html: "<p>edited</p>")

        drive.failExport = true
        _ = try await engine.pollRemoteChanges()
        #expect(try token(store) == "0")

        drive.failExport = false
        let result = try await engine.pollRemoteChanges()
        #expect(result.pulled == [a.id: .updated])
        #expect(try token(store) == "1")
    }

    @Test func expiredTokenRebaselinesAndPullsEverything() async throws {
        let (store, drive, engine) = try makeFixture()
        let a = try syncedSticky(store, drive, docId: "doc-a", html: "<p>a</p>")
        _ = try await engine.pollRemoteChanges()
        drive.remoteEdit(docId: "doc-a", html: "<p>edited</p>")

        drive.expireTokens = true
        let result = try await engine.pollRemoteChanges()

        #expect(result.pulled == [a.id: .updated])
        #expect(try token(store) == "1")
    }

    @Test func pollWithLocalEditsRaisesConflict() async throws {
        let (store, drive, engine) = try makeFixture()
        let a = try syncedSticky(store, drive, docId: "doc-a", html: "<p>a</p>")
        _ = try await engine.pollRemoteChanges()
        try engine.updateContent(stickyId: a.id, html: "<p>local</p>")
        engine.cancelDebouncedPush(stickyId: a.id)
        drive.remoteEdit(docId: "doc-a", html: "<p>remote</p>")

        let result = try await engine.pollRemoteChanges()

        #expect(result.pulled == [a.id: .conflict])
        #expect(try store.fetch(id: a.id)?.conflictBackupHTML == "<p>local</p>")
    }
}

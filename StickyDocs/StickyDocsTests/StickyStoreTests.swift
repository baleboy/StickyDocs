import Testing
import Foundation
@testable import StickyDocs

struct StickyStoreTests {

    private func makeStore() throws -> StickyStore { try StickyStore.inMemory() }

    @Test func upsertAndFetchRoundTrips() throws {
        let store = try makeStore()
        var sticky = Sticky.makeNew(title: "hello")
        sticky.contentHTML = "<p>body</p>"
        try store.upsert(sticky)

        let loaded = try store.fetch(id: sticky.id)
        #expect(loaded?.title == "hello")
        #expect(loaded?.contentHTML == "<p>body</p>")
        #expect(loaded?.googleDocId == nil)
        #expect(loaded?.pendingPush == false)
    }

    @Test func upsertOverwritesExisting() throws {
        let store = try makeStore()
        var sticky = Sticky.makeNew(title: "v1")
        try store.upsert(sticky)
        sticky.title = "v2"
        try store.upsert(sticky)
        #expect(try store.fetch(id: sticky.id)?.title == "v2")
    }

    @Test func fetchByDocId() throws {
        let store = try makeStore()
        var sticky = Sticky.makeNew()
        sticky.googleDocId = "doc-123"
        try store.upsert(sticky)

        let found = try store.fetchByDocId("doc-123")
        #expect(found?.id == sticky.id)
        #expect(try store.fetchByDocId("missing") == nil)
    }

    @Test func allActiveExcludesDeleted() throws {
        let store = try makeStore()
        let a = Sticky.makeNew(title: "alive")
        var b = Sticky.makeNew(title: "deleted")
        b.deletedLocally = true
        try store.upsert(a)
        try store.upsert(b)

        let active = try store.allActive()
        #expect(active.count == 1)
        #expect(active.first?.title == "alive")
    }

    @Test func pendingPushesOnlyReturnsDirty() throws {
        let store = try makeStore()
        var clean = Sticky.makeNew(title: "clean")
        var dirty = Sticky.makeNew(title: "dirty")
        dirty.pendingPush = true
        try store.upsert(clean)
        try store.upsert(dirty)

        let pending = try store.pendingPushes()
        #expect(pending.count == 1)
        #expect(pending.first?.title == "dirty")
    }

    @Test func deleteRemovesRow() throws {
        let store = try makeStore()
        let sticky = Sticky.makeNew()
        try store.upsert(sticky)
        try store.delete(id: sticky.id)
        #expect(try store.fetch(id: sticky.id) == nil)
    }

    @Test func appStateRoundTrips() throws {
        let store = try makeStore()
        #expect(try store.getAppState(key: "pageToken") == nil)
        try store.setAppState(key: "pageToken", value: "abc")
        #expect(try store.getAppState(key: "pageToken") == "abc")
        try store.setAppState(key: "pageToken", value: "def")
        #expect(try store.getAppState(key: "pageToken") == "def")
    }
}

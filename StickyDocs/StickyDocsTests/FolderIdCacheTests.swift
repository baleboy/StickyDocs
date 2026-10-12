import Testing
import Foundation
@testable import StickyDocs

@MainActor
struct FolderIdCacheTests {

    // Suspends until released, so the test controls when the lookup finishes.
    @MainActor private final class SlowLookup {
        var calls = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func lookup(_ name: String) async throws -> String {
            calls += 1
            await withCheckedContinuation { waiters.append($0) }
            return "folder-\(calls)"
        }

        func release() {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    @Test func concurrentCallersShareOneLookup() async throws {
        let store = try StickyStore.inMemory()
        let slow = SlowLookup()
        let cache = FolderIdCache(store: store, findOrCreateFolder: { try await slow.lookup($0) })

        async let first = cache.id()
        async let second = cache.id()
        await settle()
        slow.release()

        #expect(try await first == "folder-1")
        #expect(try await second == "folder-1")
        #expect(slow.calls == 1)
        #expect(try store.getAppState(key: OnboardingKeys.folderId) == "folder-1")
    }

    @Test func lookupFinishingAfterInvalidateIsNotCached() async throws {
        let store = try StickyStore.inMemory()
        let slow = SlowLookup()
        let cache = FolderIdCache(store: store, findOrCreateFolder: { try await slow.lookup($0) })

        async let stale = cache.id()
        await settle()
        cache.invalidate()   // e.g. sign-out while the lookup is in flight
        slow.release()
        _ = try await stale

        #expect(try store.getAppState(key: OnboardingKeys.folderId) == nil)
    }
}

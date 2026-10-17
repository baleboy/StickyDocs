import Testing
import Foundation
@testable import StickyDocs

struct FeatureTourTests {

    private func tip(_ id: String, _ version: Int) -> TourTip {
        TourTip(id: id, version: version, icon: .syncDots, title: id, text: id)
    }

    private var tips: [TourTip] { [tip("a", 1), tip("b", 1), tip("c", 2), tip("d", 3)] }

    @Test func nothingSeenShowsEveryTip() {
        #expect(FeatureTour.tipsToShow(seenVersion: nil, tips: tips).map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func olderVersionShowsOnlyNewerTips() {
        #expect(FeatureTour.tipsToShow(seenVersion: 1, tips: tips).map(\.id) == ["c", "d"])
        #expect(FeatureTour.tipsToShow(seenVersion: 2, tips: tips).map(\.id) == ["d"])
    }

    @Test func currentVersionShowsNothing() {
        #expect(FeatureTour.tipsToShow(seenVersion: 3, tips: tips).isEmpty)
    }

    @Test func tipsAreLaidOutInPages() {
        #expect(FeatureTour.pages(tips, perPage: 3).map { $0.map(\.id) } == [["a", "b", "c"], ["d"]])
        #expect(FeatureTour.pages(Array(tips.prefix(3)), perPage: 3).count == 1)
        #expect(FeatureTour.pages([], perPage: 3).isEmpty)
    }

    @Test func realTipsAreConsistent() {
        let all = FeatureTour.allTips
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(all.allSatisfy { (1...FeatureTour.currentVersion).contains($0.version) })
        // At least one tip belongs to the current version, or bumping it
        // would show an empty "What's New".
        #expect(all.contains { $0.version == FeatureTour.currentVersion })
        #expect(FeatureTour.tipsToShow(seenVersion: FeatureTour.currentVersion).isEmpty)
    }

    @Test func seenVersionRoundTripsPerDefaults() throws {
        let suite = "FeatureTourTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FeatureTour.seenVersion(in: defaults) == nil)
        FeatureTour.markSeen(in: defaults)
        #expect(FeatureTour.seenVersion(in: defaults) == FeatureTour.currentVersion)
    }

    // Sign-out and Reset All Local Data wipe the store (app_state); the tour
    // record lives outside it so they don't replay the tour.
    @MainActor @Test func wipingTheStoreKeepsTourSeen() throws {
        let suite = "FeatureTourTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        FeatureTour.markSeen(in: defaults)
        let store = try StickyStore.inMemory()
        try store.setAppState(key: OnboardingKeys.complete, value: "1")
        try store.wipeAll()
        #expect(try store.getAppState(key: OnboardingKeys.complete) == nil)
        #expect(FeatureTour.seenVersion(in: defaults) == FeatureTour.currentVersion)
    }
}

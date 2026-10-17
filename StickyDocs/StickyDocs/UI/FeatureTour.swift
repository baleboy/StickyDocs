import Foundation

// The feature tour: a few short tips, shown after setup for new users and
// once after an update for existing ones. Each tip records the tour version
// that added it, so a later update shows only its new tips ("What's New").
// When adding a feature worth a nudge, add a tip here with
// `version: currentVersion + 1` and bump `currentVersion`; when changing
// one, edit its tip. Tips are laid out `tipsPerPage` to a page.
struct TourTip: Hashable, Identifiable {
    enum Icon: Hashable {
        case symbol(String, Tint)
        // The orange and red sync dots, side by side.
        case syncDots
    }
    enum Tint: Hashable { case blue, orange, red, green, purple }

    let id: String
    let version: Int
    let icon: Icon
    let title: String
    let text: String
    // Replaces `text` while signed out, for tips that only apply once
    // stickies sync.
    var signedOutText: String? = nil
}

enum FeatureTour {
    nonisolated static let currentVersion = 1
    nonisolated static let seenVersionKey = "FeatureTour.seenVersion"
    nonisolated static let tipsPerPage = 3

    nonisolated static let allTips: [TourTip] = [
        TourTip(id: "closing", version: 1, icon: .symbol("xmark.circle.fill", .blue),
                title: "Closing isn't deleting",
                text: "✕ tucks a sticky away; find it again in All Stickies. The trash deletes it."),
        TourTip(id: "dates", version: 1, icon: .symbol("calendar", .orange),
                title: "Dates in a keystroke",
                text: "Type @today and press Tab. Also @tomorrow, @yesterday and @week."),
        TourTip(id: "dot", version: 1, icon: .syncDots,
                title: "Watch the dot",
                text: "Orange: waiting to sync. Red: needs a look. No dot: safe in Google Docs.",
                signedOutText: "Once you sign in, orange means waiting to sync, red needs a look, and no dot means safe in Google Docs."),
    ]

    // The tips to show for the version last seen on this Mac: all of them
    // if none was (a new user, or one updating to the first tour), otherwise
    // only tips added since.
    nonisolated static func tipsToShow(seenVersion: Int?, tips: [TourTip] = allTips) -> [TourTip] {
        guard let seenVersion else { return tips }
        return tips.filter { $0.version > seenVersion }
    }

    nonisolated static func pages(_ tips: [TourTip], perPage: Int = tipsPerPage) -> [[TourTip]] {
        stride(from: 0, to: tips.count, by: perPage).map { Array(tips[$0..<min($0 + perPage, tips.count)]) }
    }

    // Per Mac, in UserDefaults rather than app_state: signing out and Reset
    // All Local Data wipe app_state, and shouldn't replay the tour.
    nonisolated static func seenVersion(in defaults: UserDefaults = .standard) -> Int? {
        defaults.object(forKey: seenVersionKey) as? Int
    }

    nonisolated static func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: seenVersionKey)
    }
}

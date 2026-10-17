import Testing
import Foundation
@testable import StickyDocs

@MainActor
struct LauncherTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }
    private let locale = Locale(identifier: "en_US")

    // Saturday 2026-10-17 15:00 local.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 15))!
    }

    private func label(_ date: Date) -> String {
        LauncherDate.string(for: date, relativeTo: now, calendar: calendar, locale: locale)
    }

    private func daysAgo(_ n: Int, hour: Int = 12) -> Date {
        let day = calendar.date(byAdding: .day, value: -n, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    @Test func todayIsRelative() {
        #expect(label(now.addingTimeInterval(-10)) == "Just now")
        #expect(label(now.addingTimeInterval(-120)) == "2 min ago")
        #expect(label(now.addingTimeInterval(-3_600)) == "1 hr ago")
        #expect(label(calendar.startOfDay(for: now)) == "15 hr ago")
    }

    @Test func yesterdayThenWeekdayThenDate() {
        #expect(label(daysAgo(1, hour: 23)) == "Yesterday")
        #expect(label(daysAgo(2)) == "Thursday")
        #expect(label(daysAgo(6)) == "Sunday")
        #expect(label(daysAgo(7)) == "Oct 10")
        #expect(label(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 9))!) == "Oct 3")
        #expect(label(calendar.date(from: DateComponents(year: 2025, month: 10, day: 3, hour: 9))!) == "Oct 3, 2025")
    }

    @Test func syncedPhrasing() {
        #expect(LauncherDate.syncedString(for: now.addingTimeInterval(-120), relativeTo: now, calendar: calendar) == "Synced 2 min ago")
        #expect(LauncherDate.syncedString(for: now, relativeTo: now, calendar: calendar) == "Synced just now")
        #expect(LauncherDate.syncedString(for: daysAgo(1), relativeTo: now, calendar: calendar) == "Synced yesterday")
    }

    @Test func titleFallsBackToFirstLineThenUntitled() {
        let a = AllStickiesViewModel.titleAndPreview(title: "Groceries", plainText: "Groceries\nmilk\neggs\n")
        #expect(a.title == "Groceries" && a.preview == "milk eggs")
        let b = AllStickiesViewModel.titleAndPreview(title: "  ", plainText: "\nFirst line\nsecond   line\n")
        #expect(b.title == "First line" && b.preview == "second line")
        let c = AllStickiesViewModel.titleAndPreview(title: "", plainText: "\n  \n")
        #expect(c.title == "(Untitled)" && c.preview == "")
        // A stale title (first line edited since) keeps the whole text as preview.
        let d = AllStickiesViewModel.titleAndPreview(title: "Old", plainText: "New first\nmore")
        #expect(d.title == "Old" && d.preview == "New first more")
    }

    @Test func previewDropsListMarkers() {
        let html = "<p>Todo</p><ul><li>one</li><li>two</li></ul><ol><li>three</li></ol>"
        let plain = HTMLNormalizer.attributedString(from: html).string
        let r = AllStickiesViewModel.titleAndPreview(title: "", plainText: plain)
        #expect(r.title == "Todo" && r.preview == "one two three")
    }

    @Test func selectionMovesAndClamps() {
        let items = (1...3).map {
            LauncherItem(id: "\($0)", title: "t", preview: "", color: "yellow", modified: Date())
        }
        let vm = AllStickiesViewModel(items: items)
        #expect(vm.selection == "1")
        vm.moveSelection(by: -1)
        #expect(vm.selection == "1")
        vm.moveSelection(by: 1); vm.moveSelection(by: 1); vm.moveSelection(by: 1)
        #expect(vm.selection == "3")
        vm.selectFirst()
        #expect(vm.selection == "1")
    }
}

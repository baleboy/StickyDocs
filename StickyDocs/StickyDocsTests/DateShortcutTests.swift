import Testing
import AppKit
@testable import StickyDocs

@MainActor
struct DateShortcutTests {

    private func calendar(_ zone: String = "Europe/Helsinki") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ iso: String, _ zone: String = "Europe/Helsinki") -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: iso)!
    }

    private func expand(_ keyword: String, at iso: String, locale: String = "en_GB",
                        zone: String = "Europe/Helsinki") -> String? {
        DateShortcut.expansion(for: keyword, now: date(iso, zone), calendar: calendar(zone),
                               locale: Locale(identifier: locale))
    }

    // MARK: - Values

    @Test func datesUseLocaleMediumStyle() {
        #expect(expand("today", at: "2026-10-17T12:00:00") == "17 Oct 2026")
        #expect(expand("today", at: "2026-10-17T12:00:00", locale: "en_US") == "Oct 17, 2026")
        #expect(expand("tomorrow", at: "2026-10-17T12:00:00") == "18 Oct 2026")
        #expect(expand("yesterday", at: "2026-10-17T12:00:00") == "16 Oct 2026")
    }

    @Test func keywordsIgnoreCase() {
        #expect(expand("Today", at: "2026-10-17T12:00:00") == "17 Oct 2026")
        #expect(expand("WEEK", at: "2026-10-17T12:00:00") == "W42")
        #expect(expand("foo", at: "2026-10-17T12:00:00") == nil)
    }

    @Test func relativeDaysCrossMonthAndYearEnds() {
        #expect(expand("tomorrow", at: "2026-12-31T23:30:00") == "1 Jan 2027")
        #expect(expand("yesterday", at: "2027-01-01T00:10:00") == "31 Dec 2026")
        #expect(expand("tomorrow", at: "2028-02-28T08:00:00") == "29 Feb 2028")
    }

    @Test func relativeDaysAcrossDST() {
        // Helsinki leaves DST on 25 Oct 2026; that day is 25 hours long.
        #expect(expand("tomorrow", at: "2026-10-24T23:30:00") == "25 Oct 2026")
        #expect(expand("tomorrow", at: "2026-10-25T00:30:00") == "26 Oct 2026")
        #expect(expand("yesterday", at: "2026-10-26T00:30:00") == "25 Oct 2026")
        // ...and enters it on 29 Mar 2026 (23 hours).
        #expect(expand("tomorrow", at: "2026-03-28T23:30:00") == "29 Mar 2026")
        #expect(expand("yesterday", at: "2026-03-30T00:30:00") == "29 Mar 2026")
    }

    @Test func weekIsISO8601WhateverTheLocale() {
        #expect(expand("week", at: "2026-10-17T12:00:00") == "W42")
        #expect(expand("week", at: "2026-10-17T12:00:00", locale: "en_US") == "W42")
        #expect(expand("week", at: "2025-12-29T12:00:00") == "W1")
        #expect(expand("week", at: "2026-12-31T12:00:00") == "W53")
        #expect(expand("week", at: "2027-01-01T12:00:00") == "W53")
        #expect(expand("week", at: "2027-01-04T12:00:00") == "W1")
        // Sunday still belongs to the week that started on Monday.
        #expect(expand("week", at: "2026-10-18T23:59:00", locale: "en_US") == "W42")
    }

    // MARK: - Token boundaries

    private func keyword(in text: String) -> String? {
        DateShortcut.token(endingAt: (text as NSString).length, in: text as NSString)?.keyword
    }

    @Test func tokenBoundaries() {
        #expect(keyword(in: "@today") == "today")
        #expect(keyword(in: "Meeting @Today") == "Today")
        #expect(keyword(in: "line\n@week") == "week")
        #expect(keyword(in: "a\t@week") == "week")
        #expect(keyword(in: "(@tomorrow") == "tomorrow")
        #expect(keyword(in: "“@yesterday") == "yesterday")
        for text in ["bob@today", "x@week", "@todays", "@today.", "@today.com", "@foo", "today", "@", "@@today", "a.@today"] {
            #expect(keyword(in: text) == nil, "\(text)")
        }
    }

    @Test func tokenRangeCoversAtSign() {
        let text = "due @week" as NSString
        #expect(DateShortcut.token(endingAt: text.length, in: text)?.range == NSRange(location: 4, length: 5))
        // Only a token ending exactly at the given location.
        #expect(DateShortcut.token(endingAt: 6, in: "@today later" as NSString)?.keyword == "today")
        #expect(DateShortcut.token(endingAt: 5, in: "@today later" as NSString) == nil)
    }

    // MARK: - Editor

    private var today: String { DateShortcut.expansion(for: "today")! }
    private var week: String { DateShortcut.expansion(for: "week")! }

    @Test func spaceTabAndReturnExpand() {
        let e = EditorHarness()
        e.type("Meeting @today notes")
        #expect(e.textView.string == "Meeting \(today) notes")
        let tab = EditorHarness()
        tab.type("@week")
        tab.textView.insertTab(nil)
        #expect(tab.textView.string == "\(week)")
        let ret = EditorHarness()
        ret.type("@week\nnext")
        #expect(ret.html == "<p>\(week)</p><p>next</p>")
    }

    @Test func emailLikeAndUnknownTextIsLeftAlone() {
        let e = EditorHarness()
        e.type("bob@today @todays @foo @today. done")
        #expect(e.textView.string == "bob@today @todays @foo @today. done")
    }

    @Test func expandsMidParagraph() {
        let e = EditorHarness(html: "<p>due ok</p>")
        e.textView.setSelectedRange(NSRange(location: 4, length: 0))
        e.type("@week ")
        #expect(e.html == "<p>due \(week) ok</p>")
        e.type("x")
        #expect(e.html == "<p>due \(week) xok</p>")
    }

    @Test func undoBringsBackKeyword() {
        let e = EditorHarness()
        e.type("on @today ")
        #expect(e.textView.string == "on \(today) ")
        e.undo()
        #expect(e.textView.string == "on @today ")
    }

    @Test func pasteIsNotExpanded() {
        let e = EditorHarness()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("on @today ok", forType: .string)
        e.textView.pasteAsPlainText(nil)
        #expect(e.textView.string == "on @today ok")
    }

    @Test func keepsFormattingAndListItem() {
        let bold = EditorHarness(html: "<p><b>x</b></p>")
        bold.textView.setSelectedRange(NSRange(location: 1, length: 0))
        bold.type(" @week ")
        #expect(bold.html == "<p><b>x \(week) </b></p>")
        let list = EditorHarness()
        list.type("- @week\nnext")
        #expect(list.html == "<ul><li>\(week)</li><li>next</li></ul>")
    }

    @Test func linkedKeywordIsLeftAlone() {
        let e = EditorHarness(html: #"<p><a href="https://example.com/">@today</a></p>"#)
        e.textView.setSelectedRange(NSRange(location: 6, length: 0))
        e.type(" ")
        #expect(e.html == #"<p><a href="https://example.com/">@today</a> </p>"#)
    }

    @Test func expansionMarksStickyChanged() {
        final class Spy: NSObject, NSTextViewDelegate { var count = 0; func textDidChange(_ n: Notification) { count += 1 } }
        let e = EditorHarness()
        let spy = Spy()
        e.textView.delegate = spy
        e.type("@week")
        let before = spy.count
        e.type(" ")
        #expect(spy.count > before + 1)  // the space, then the expansion
    }

    @Test func linksStillDetectedAlongside() {
        let e = EditorHarness()
        e.type("@week https://example.com ")
        #expect(e.html == #"<p>\#(week) <a href="https://example.com/">https://example.com</a> </p>"#)
    }
}

@MainActor
struct DateShortcutHintTests {
    private var today: String { DateShortcut.expansion(for: "today")! }

    @Test func hintShowsOnlyForACompleteKeyword() {
        let e = EditorHarness()
        e.type("on @tod")
        #expect(e.textView.dateHint == nil)
        e.type("ay")
        #expect(e.textView.dateHint?.range == NSRange(location: 3, length: 6))
        #expect(e.textView.dateHint?.value == today)
        #expect(e.textView.isDateHintPreviewVisible)
        e.type("s")
        #expect(e.textView.dateHint == nil)
    }

    @Test func hintGoesAwayOnExpansionAndCursorMove() {
        let e = EditorHarness()
        e.type("@today")
        #expect(e.textView.dateHint != nil)
        e.textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(e.textView.dateHint == nil)
        e.textView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(e.textView.dateHint != nil)
        e.type(" ")
        #expect(e.textView.dateHint == nil)
    }

    @Test func previewOnlyAtEndOfLine() {
        let e = EditorHarness(html: "<p>due ok</p>")
        e.textView.setSelectedRange(NSRange(location: 3, length: 0))
        e.type(" @today")
        #expect(e.textView.dateHint != nil)  // tinted
        #expect(!e.textView.isDateHintPreviewVisible)
    }

    @Test func hintIsDisplayOnly() {
        let e = EditorHarness()
        e.type("@today")
        #expect(e.html == "<p>@today</p>")
    }

    @Test func escapeKeepsKeywordLiteral() {
        let e = EditorHarness()
        e.type("on @today")
        e.textView.cancelOperation(nil)
        #expect(e.textView.dateHint == nil)
        e.type(" later")
        #expect(e.textView.string == "on @today later")
    }

    @Test func editingDismissedKeywordRearmsIt() {
        let e = EditorHarness()
        e.type("@today")
        e.textView.cancelOperation(nil)
        e.textView.deleteBackward(nil)
        e.type("y")
        #expect(e.textView.dateHint != nil)
        e.type(" ")
        #expect(e.textView.string == "\(today) ")
    }

    @Test func dismissalFollowsEditsBeforeIt() {
        let e = EditorHarness()
        e.type("x @today")
        e.textView.cancelOperation(nil)
        e.textView.setSelectedRange(NSRange(location: 0, length: 0))
        e.type("more ")
        e.textView.setSelectedRange(NSRange(location: (e.textView.string as NSString).length, length: 0))
        #expect(e.textView.dateHint == nil)
        e.type(" ")
        #expect(e.textView.string == "more x @today ")
    }

    @Test func dismissalOnlyAppliesToThatKeyword() {
        let e = EditorHarness()
        e.type("@today")
        e.textView.cancelOperation(nil)
        e.type(" and @today ")
        #expect(e.textView.string == "@today and \(today) ")
    }

    @Test func tabAcceptsWithoutInsertingTab() {
        let e = EditorHarness()
        e.type("on @today")
        e.textView.insertTab(nil)
        #expect(e.textView.string == "on \(today)")
        #expect(e.textView.selectedRange() == NSRange(location: ("on \(today)" as NSString).length, length: 0))
        e.undo()
        #expect(e.textView.string == "on @today")
    }

    @Test func tabWithoutHintInsertsTab() {
        let e = EditorHarness()
        e.type("@today")
        e.textView.cancelOperation(nil)
        e.textView.insertTab(nil)
        #expect(e.textView.string == "@today\t")
        let plain = EditorHarness()
        plain.type("a")
        plain.textView.insertTab(nil)
        #expect(plain.textView.string == "a\t")
    }

    @Test func tabAcceptsMidLine() {
        let e = EditorHarness(html: "<p>due ok</p>")
        e.textView.setSelectedRange(NSRange(location: 3, length: 0))
        e.type(" @today")
        e.textView.insertTab(nil)
        #expect(e.html == "<p>due \(today) ok</p>")
    }

    @Test func noHintWhenAWordFollows() {
        let e = EditorHarness(html: "<p>@todayok</p>")
        e.textView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(e.textView.dateHint == nil)
        // Tab is then an ordinary trigger: the tab separates the keyword,
        // which expands as with a space.
        e.textView.insertTab(nil)
        #expect(e.textView.string.hasPrefix("\(today)\tok"))
    }
}

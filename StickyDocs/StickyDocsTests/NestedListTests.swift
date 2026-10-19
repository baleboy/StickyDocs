import Testing
import AppKit
@testable import StickyDocs

// Lists nested with Tab in the editor serialize as nested <ul>/<ol>, load
// back at the same levels, reach the Doc as nested list items, and come back
// from Drive's export (which doesn't nest its HTML) at the same levels.
@MainActor
struct NestedListTests {

    private func roundTrip(_ html: String) -> String {
        HTMLNormalizer.html(from: HTMLNormalizer.attributedString(from: html))
    }

    @Test func tabNestedItemsSerializeNested() {
        let e = EditorHarness()
        e.type("- a\n")
        e.textView.insertTab(nil)
        e.type("b\n")
        e.textView.insertTab(nil)
        e.type("c\n")
        e.textView.insertBacktab(nil)
        e.textView.insertBacktab(nil)
        e.type("d")
        #expect(e.html == "<ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li><li>d</li></ul>")
    }

    @Test func tabInNumberedListNestsABulletedList() {
        // NSTextView nests a hyphen list under a numbered item, and the
        // HTML says what the sticky shows.
        let e = EditorHarness()
        e.type("1. a\n")
        e.textView.insertTab(nil)
        e.type("b")
        #expect(e.html == "<ol><li>a<ul><li>b</li></ul></li></ol>")
        #expect(EditorHarness(html: e.html).textView.string == e.textView.string)
    }

    @Test func nestedListsRoundTrip() {
        for html in [
            "<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul>",
            "<ol><li>a<ol><li>b</li></ol></li><li>c</li></ol>",
            "<ul><li>a<ol><li>b</li></ol></li></ul>",
            "<ul><li>a<ul><li>b<ul><li>c</li></ul></li></ul></li></ul><p>end</p>",
            "<ul><li>a</li><li>b</li></ul>",
        ] {
            #expect(roundTrip(html) == html)
        }
    }

    @Test func loadedNestedListMatchesTypedOne() {
        let typed = EditorHarness()
        typed.type("- a\n")
        typed.textView.insertTab(nil)
        typed.type("b")
        let loaded = EditorHarness(html: typed.html)
        #expect(loaded.textView.string == typed.textView.string)
        #expect(loaded.html == typed.html)
    }

    // Shape of Drive's files.export text/html for nested lists: each level
    // is a separate top-level list, its level only in the lst-kix class.
    static let driveExportNested = """
    <html><head><style type="text/css">.lst-kix_abc-1>li:before{content:"\\0025cb   "}\
    ul.lst-kix_abc-0{list-style-type:none}.c1{margin-left:36pt}.c3{margin-left:72pt}</style></head>\
    <body class="c5"><ul class="c2 lst-kix_abc-0 start"><li class="c1 li-bullet-0"><span class="c0">a</span></li></ul>\
    <ul class="c2 lst-kix_abc-1 start"><li class="c3 li-bullet-1"><span class="c0">b</span></li>\
    <li class="c3 li-bullet-1"><span class="c0">c</span></li></ul>\
    <ul class="c2 lst-kix_abc-0"><li class="c1 li-bullet-0"><span class="c0">d</span></li></ul>\
    <p class="c4"><span class="c0">end</span></p>\
    <ol class="c2 lst-kix_num-0 start" start="1"><li class="c1 li-bullet-0"><span class="c0">one</span></li></ol>\
    <ol class="c2 lst-kix_num-1 start" start="1"><li class="c3 li-bullet-1"><span class="c0">sub</span></li></ol></body></html>
    """

    @Test func driveExportListsAreNestedByLevel() {
        #expect(roundTrip(Self.driveExportNested) ==
                "<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul><p>end</p>"
                + "<ol><li>one<ol><li>sub</li></ol></li></ol>")
    }

    @Test func flatDriveExportListsAreLeftAlone() {
        let html = #"<ul class="c2 lst-kix_x-0 start"><li class="c1">a</li></ul><p>b</p>"#
        #expect(HTMLNormalizer.nestDocsExportLists(html) == html)
    }

    private func encodedRequests(_ html: String) throws -> [[String: Any]] {
        let attr = HTMLNormalizer.attributedString(from: html)
        let data = try JSONEncoder().encode(DocsBatchEncoder.encode(attr, currentBodyEndIndex: 2).requests)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    @Test func encoderIndentsNestedItemsWithTabs() throws {
        let requests = try encodedRequests("<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>")
        let insert = try #require(requests.compactMap { $0["insertText"] as? [String: Any] }.first)
        #expect(insert["text"] as? String == "a\n\tb\nc")
        let bullets = requests.compactMap { $0["createParagraphBullets"] as? [String: Any] }
        #expect(bullets.count == 1)
        #expect(bullets.first?["range"] as? [String: Int] == ["startIndex": 1, "endIndex": 8])
    }

    @Test func encoderAddsBulletsFromTheEnd() throws {
        // Each createParagraphBullets removes its tabs, so a later range must
        // be bulleted first or its indices would be stale.
        let requests = try encodedRequests("<ul><li>a</li></ul><ol><li>b<ol><li>c</li></ol></li></ol>")
        let bullets = requests.compactMap { $0["createParagraphBullets"] as? [String: Any] }
        #expect(bullets.map { $0["range"] as? [String: Int] } == [
            ["startIndex": 3, "endIndex": 8], ["startIndex": 1, "endIndex": 3]
        ])
        #expect(bullets.map { $0["bulletPreset"] as? String } == [
            "NUMBERED_DECIMAL_ALPHA_ROMAN", "BULLET_DISC_CIRCLE_SQUARE"
        ])
    }
}

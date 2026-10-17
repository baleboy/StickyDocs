import Testing
import AppKit
@testable import StickyDocs

@MainActor
struct LinkSyncTests {

    private func roundTrip(_ html: String) -> String {
        HTMLNormalizer.html(from: HTMLNormalizer.attributedString(from: html))
    }

    private func assertIdempotent(_ html: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let first = roundTrip(html)
        #expect(first == roundTrip(first), "not idempotent: \(first)", sourceLocation: sourceLocation)
    }

    // MARK: - HTMLNormalizer

    @Test func linkSurvivesRoundTrip() {
        let out = roundTrip(#"<p>see <a href="https://example.com/a?b=1&amp;c=2">example</a> here</p>"#)
        #expect(out == #"<p>see <a href="https://example.com/a?b=1&amp;c=2">example</a> here</p>"#)
    }

    @Test func linkIsNotUnderlined() {
        // AppKit's importer underlines link text; that must not become <u>.
        #expect(!roundTrip(#"<p><a href="https://example.com/">x</a></p>"#).contains("<u>"))
    }

    @Test func linkWithBoldAndItalic() {
        let out = roundTrip(#"<p><a href="https://example.com/"><b><i>both</i></b></a></p>"#)
        #expect(out == #"<p><a href="https://example.com/"><b><i>both</i></b></a></p>"#)
    }

    @Test func linkAtEndOfParagraph() {
        assertIdempotent(#"<p>end <a href="https://example.com/">here</a></p><p>next</p>"#)
        #expect(roundTrip(#"<p>end <a href="https://example.com/">here</a></p><p>next</p>"#)
            == #"<p>end <a href="https://example.com/">here</a></p><p>next</p>"#)
    }

    @Test func linkInsideListItem() {
        let html = #"<ul><li>go <a href="https://example.com/">site</a></li><li>two</li></ul>"#
        #expect(roundTrip(html) == html)
    }

    @Test func mailtoIsKept() {
        let html = #"<p><a href="mailto:a@example.com">a@example.com</a></p>"#
        #expect(roundTrip(html) == html)
    }

    @Test func disallowedSchemesKeepTextButLoseLink() {
        for href in ["javascript:alert(1)", "file:///etc/passwd", "ftp://example.com/x"] {
            #expect(roundTrip("<p><a href=\"\(href)\">text</a></p>") == "<p>text</p>", "\(href)")
        }
    }

    @Test func emptyPathIsCanonicalized() {
        let attr = NSAttributedString(string: "x", attributes: [.link: URL(string: "https://example.com")!])
        let html = HTMLNormalizer.html(from: attr)
        #expect(html == #"<p><a href="https://example.com/">x</a></p>"#)
        #expect(roundTrip(html) == html)
    }

    @Test func hrefIsEscaped() {
        let attr = NSAttributedString(string: "q", attributes: [.link: URL(string: "https://e.com/?a=1&b=%22x%22")!])
        let html = HTMLNormalizer.html(from: attr)
        #expect(html == #"<p><a href="https://e.com/?a=1&amp;b=%22x%22">q</a></p>"#)
        #expect(roundTrip(html) == html)
    }

    @Test func contentWithoutLinksIsUnchanged() {
        for (_, html) in RoundTripHarness.defaultCases where !html.contains("<a ") {
            #expect(!roundTrip(html).contains("<a "))
        }
        #expect(roundTrip("<p>hello <b>bold</b> <u>under</u></p>") == "<p>hello <b>bold</b> <u>under</u></p>")
    }

    // Shape of Drive's files.export text/html output for a Doc with a link:
    // class-based CSS (link color + underline on the span) and every href
    // wrapped in a google.com/url redirect.
    static let driveExportWithLink = """
        <html><head><meta content="text/html; charset=UTF-8" http-equiv="content-type"><style type="text/css">\
        .c0{color:#000000;font-weight:400;text-decoration:none;vertical-align:baseline;font-size:11pt;font-family:"Arial";font-style:normal}\
        .c1{color:#1155cc;text-decoration:underline}.c2{color:inherit;text-decoration:inherit}\
        .c3{padding-top:0pt;padding-bottom:0pt;line-height:1.15;orphans:2;widows:2;text-align:left}\
        .c4{font-weight:700}\
        </style></head><body class="c5 doc-content"><p class="c3"><span class="c0">see&nbsp;</span>\
        <span class="c1"><a class="c2" href="https://www.google.com/url?q=https://example.com/path?x%3D1&amp;sa=D&amp;source=editors&amp;ust=1760000000000000&amp;usg=AOvVaw0abc">example</a></span>\
        <span class="c0">&nbsp;and&nbsp;</span><span class="c1 c4"><a class="c2" href="https://www.google.com/url?q=https://bold.example.org/&amp;sa=D&amp;source=editors&amp;ust=1&amp;usg=x">bold</a></span></p></body></html>
        """

    @Test func driveExportLinksAreUnwrappedAndNotUnderlined() {
        let out = roundTrip(Self.driveExportWithLink)
        #expect(out == #"<p>see <a href="https://example.com/path?x=1">example</a> and <a href="https://bold.example.org/"><b>bold</b></a></p>"#)
    }

    // MARK: - DocsBatchEncoder

    private func encodedRequests(_ html: String) throws -> [[String: Any]] {
        let attr = HTMLNormalizer.attributedString(from: html)
        let requests = DocsBatchEncoder.encode(attr, currentBodyEndIndex: 2).requests
        let data = try JSONEncoder().encode(requests)
        return try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    @Test func encoderWritesLinkStyle() throws {
        let requests = try encodedRequests(#"<p>see <a href="https://example.com/">site</a></p>"#)
        let styles = requests.compactMap { $0["updateTextStyle"] as? [String: Any] }
        let linkStyle = try #require(styles.first { (($0["textStyle"] as? [String: Any])?["link"]) != nil })
        let range = try #require(linkStyle["range"] as? [String: Int])
        #expect(range["startIndex"] == 5 && range["endIndex"] == 9)
        let textStyle = try #require(linkStyle["textStyle"] as? [String: Any])
        #expect((textStyle["link"] as? [String: String])?["url"] == "https://example.com/")
        #expect(textStyle["underline"] as? Bool == true)
        let fields = (linkStyle["fields"] as? String)?.split(separator: ",").map(String.init) ?? []
        #expect(Set(fields) == ["underline", "link", "foregroundColor"])
    }

    @Test func encoderResetClearsLinks() throws {
        let requests = try encodedRequests("<p>plain</p>")
        let reset = try #require(requests.compactMap { $0["updateTextStyle"] as? [String: Any] }.first)
        let fields = (reset["fields"] as? String)?.split(separator: ",").map(String.init) ?? []
        #expect(fields.contains("link") && fields.contains("foregroundColor"))
        #expect((reset["textStyle"] as? [String: Any])?["link"] == nil)
    }

    @Test func encoderKeepsBoldOnLink() throws {
        let requests = try encodedRequests(#"<p><a href="https://example.com/"><b>x</b></a></p>"#)
        let styles = requests.compactMap { $0["updateTextStyle"] as? [String: Any] }.dropFirst()
        let textStyle = try #require(styles.first?["textStyle"] as? [String: Any])
        #expect(textStyle["bold"] as? Bool == true)
        #expect(textStyle["link"] != nil)
    }
}

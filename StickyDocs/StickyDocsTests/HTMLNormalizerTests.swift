import Testing
import AppKit
@testable import StickyDocs

@MainActor
struct HTMLNormalizerTests {

    private func roundTrip(_ html: String) -> String {
        let attr = HTMLNormalizer.attributedString(from: html)
        return HTMLNormalizer.html(from: attr)
    }

    /// Parsing then serializing should be idempotent on the second pass:
    /// however lossy the first parse is, a second round-trip must agree
    /// with the first. This is the property the sync engine relies on.
    private func assertIdempotent(_ html: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let first = roundTrip(html)
        let second = roundTrip(first)
        #expect(first == second, "Round-trip not idempotent.\nfirst:  \(first)\nsecond: \(second)", sourceLocation: sourceLocation)
    }

    // MARK: - Idempotence across the supported subset

    @Test func emptyIsIdempotent() { assertIdempotent("") }
    @Test func plainParagraphIsIdempotent() { assertIdempotent("<p>hello world</p>") }
    @Test func boldIsIdempotent() { assertIdempotent("<p>hello <b>bold</b> world</p>") }
    @Test func italicIsIdempotent() { assertIdempotent("<p><i>italic</i></p>") }
    @Test func underlineIsIdempotent() { assertIdempotent("<p><u>under</u></p>") }
    @Test func boldItalicIsIdempotent() { assertIdempotent("<p><b><i>both</i></b></p>") }
    @Test func allThreeStylesIsIdempotent() { assertIdempotent("<p><b><i><u>all three</u></i></b></p>") }
    @Test func multipleParagraphsIsIdempotent() { assertIdempotent("<p>one</p><p>two</p>") }
    @Test func bulletedListIsIdempotent() { assertIdempotent("<ul><li>one</li><li>two</li></ul>") }
    @Test func numberedListIsIdempotent() { assertIdempotent("<ol><li>one</li><li>two</li></ol>") }
    @Test func mixedDocumentIsIdempotent() {
        assertIdempotent("<p>intro</p><ul><li>a</li><li>b</li></ul><p>end</p>")
    }
    @Test func consecutiveSameListsCollapseIsIdempotent() {
        assertIdempotent("<ul><li>a</li></ul><ul><li>b</li></ul>")
    }

    // MARK: - Content preservation

    @Test func boldContentSurvivesRoundTrip() {
        let out = roundTrip("<p>hello <b>bold</b> world</p>")
        #expect(out.contains("<b>bold</b>"))
        #expect(out.contains("hello"))
        #expect(out.contains("world"))
    }

    @Test func bulletItemsSurviveRoundTrip() {
        let out = roundTrip("<ul><li>one</li><li>two</li><li>three</li></ul>")
        #expect(out.contains("<ul>"))
        #expect(out.contains("<li>one</li>"))
        #expect(out.contains("<li>two</li>"))
        #expect(out.contains("<li>three</li>"))
        #expect(out.contains("</ul>"))
    }

    @Test func numberedItemsSurviveRoundTrip() {
        let out = roundTrip("<ol><li>first</li><li>second</li></ol>")
        #expect(out.contains("<ol>"))
        #expect(out.contains("<li>first</li>"))
        #expect(out.contains("<li>second</li>"))
        #expect(out.contains("</ol>"))
    }

    // MARK: - Lossy normalization

    @Test func droppedStylesAreNotPreserved() {
        // Color, size, font family, alignment are all out of scope and must be stripped.
        let out = roundTrip("""
            <p style="color:red;font-size:24px;font-family:Helvetica;text-align:center">styled</p>
            """)
        #expect(out.contains("styled"))
        #expect(!out.contains("red"))
        #expect(!out.contains("24px"))
        #expect(!out.contains("Helvetica"))
        #expect(!out.contains("center"))
    }

    @Test func headingsAreFlattenedToParagraphs() {
        // Out of scope for v1 - headings should not survive round-trip as headings.
        let out = roundTrip("<h1>heading</h1>")
        #expect(out.contains("heading"))
        #expect(!out.contains("<h1>"))
    }

    @Test func htmlEscapesAreHandled() {
        let out = roundTrip("<p>5 &lt; 10 &amp; 10 &gt; 5</p>")
        #expect(out.contains("5 &lt; 10"))
        #expect(out.contains("10 &gt; 5"))
        #expect(out.contains("&amp;"))
    }
}

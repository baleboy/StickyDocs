import Testing
import AppKit
@testable import StickyDocs

// Drives a real StickyNSTextView (TextKit 1, like StickyTextEditor builds it)
// hosted in an off-screen window, so typing, undo and data detection behave
// as in the app.
@MainActor
final class EditorHarness {
    let window: NSWindow
    let textView: StickyNSTextView

    init(html: String = "") {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        textView = StickyNSTextView(frame: window.contentView!.bounds, textContainer: container)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.font = NSFont.systemFont(ofSize: 14)
        window.contentView!.addSubview(textView)
        storage.setAttributedString(HTMLNormalizer.attributedString(from: html))
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: storage.length, length: 0))
    }

    var html: String { HTMLNormalizer.html(from: NSAttributedString(attributedString: textView.textStorage!)) }

    func type(_ text: String) {
        for ch in text {
            if ch == "\n" { textView.insertNewline(nil) }
            else { textView.insertText(String(ch), replacementRange: textView.selectedRange()) }
        }
    }

    func undo() { window.undoManager?.undo() }

    deinit { MainActor.assumeIsolated { window.close() } }
}

@MainActor
struct StickyEditorTests {

    // MARK: - List shortcut trigger rules

    @Test func shortcutTriggers() {
        #expect(StickyNSTextView.listShortcut(forParagraphPrefix: "-") == .bullet)
        #expect(StickyNSTextView.listShortcut(forParagraphPrefix: "*") == .bullet)
        #expect(StickyNSTextView.listShortcut(forParagraphPrefix: "1.") == .numbered)
        #expect(StickyNSTextView.listShortcut(forParagraphPrefix: "1)") == .numbered)
        for other in ["2.", "10.", "a -", "see 1.", "--", " -", "", "1"] {
            #expect(StickyNSTextView.listShortcut(forParagraphPrefix: other) == nil, "\(other)")
        }
    }

    @Test func dashSpaceStartsBulletedList() {
        let e = EditorHarness()
        e.type("- milk")
        #expect(e.html == "<ul><li>milk</li></ul>")
    }

    @Test func starSpaceStartsBulletedList() {
        let e = EditorHarness()
        e.type("* milk")
        #expect(e.html == "<ul><li>milk</li></ul>")
    }

    @Test func oneDotStartsNumberedList() {
        let e = EditorHarness()
        e.type("1. first\nsecond")
        #expect(e.html == "<ol><li>first</li><li>second</li></ol>")
    }

    @Test func oneParenStartsNumberedList() {
        let e = EditorHarness()
        e.type("1) first")
        #expect(e.html == "<ol><li>first</li></ol>")
    }

    @Test func shortcutOnlyAtStartOfParagraph() {
        let e = EditorHarness()
        e.type("a - b\nsee 1. above\n2. two\n10. ten")
        #expect(e.html == "<p>a - b</p><p>see 1. above</p><p>2. two</p><p>10. ten</p>")
    }

    @Test func shortcutOnLaterParagraph() {
        let e = EditorHarness()
        e.type("intro\n- a\nb")
        #expect(e.html == "<p>intro</p><ul><li>a</li><li>b</li></ul>")
    }

    @Test func noShortcutInsideExistingList() {
        let e = EditorHarness(html: "<ul><li>x</li></ul>")
        e.textView.setSelectedRange(NSRange(location: (e.textView.string as NSString).length - 1, length: 0))
        e.type("\n- y")
        #expect(e.html == "<ul><li>x</li><li>- y</li></ul>")
    }

    @Test func pasteIsNotConverted() {
        let e = EditorHarness()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("- pasted", forType: .string)
        e.textView.pasteAsPlainText(nil)
        e.type(" more")
        #expect(e.html == "<p>- pasted more</p>")
    }

    @Test func shortcutMatchesListLoadedFromHTML() throws {
        let typed = EditorHarness()
        typed.type("- a\nb")
        let loaded = EditorHarness(html: "<ul><li>a</li><li>b</li></ul>")
        #expect(typed.html == loaded.html)
        let encode = { (tv: NSTextView) throws -> Data in
            try JSONEncoder().encode(DocsBatchEncoder.encode(tv.textStorage!, currentBodyEndIndex: 2).requests)
        }
        #expect(try encode(typed.textView) == encode(loaded.textView))
    }

    @Test func undoRestoresLiteralMarker() {
        let e = EditorHarness()
        e.type("- ")
        #expect(e.html == "<ul><li></li></ul>")
        e.undo()
        #expect(e.textView.string == "- ")
        #expect(e.html == "<p>- </p>")
    }

    @Test func bulletsUseSpotGlyph() {
        let loaded = EditorHarness(html: "<ul><li>a</li></ul>")
        #expect(loaded.textView.string.hasPrefix("\t⦁\ta"))
        let typed = EditorHarness()
        typed.type("- a\nb")
        #expect(typed.textView.string.hasPrefix("\t⦁\ta\n\t⦁\tb"))
        #expect(typed.html == "<ul><li>a</li><li>b</li></ul>")
    }

    @Test func returnOnEmptyItemEndsList() {
        let e = EditorHarness()
        e.type("- a\n\nafter")
        #expect(e.html == "<ul><li>a</li></ul><p>after</p>")
    }

    @Test func backspaceAtStartOfItemRemovesBullet() {
        let e = EditorHarness(html: "<ul><li>one</li><li>two</li></ul>")
        // Put the cursor right after the second item's marker.
        let ns = e.textView.string as NSString
        e.textView.setSelectedRange(NSRange(location: ns.range(of: "two").location, length: 0))
        e.textView.deleteBackward(nil)
        #expect(e.html == "<ul><li>one</li></ul><p>two</p>")
        e.type("x")
        #expect(e.html == "<ul><li>one</li></ul><p>xtwo</p>")
    }

    @Test func formatMenuTogglesList() {
        let e = EditorHarness(html: "<p>a</p><p>b</p>")
        e.textView.selectAll(nil)
        e.textView.toggleNumberedList(nil)
        #expect(e.html == "<ol><li>a</li><li>b</li></ol>")
        e.textView.selectAll(nil)
        e.textView.toggleNumberedList(nil)
        #expect(e.html == "<p>a</p><p>b</p>")
    }

    @Test func shortcutMarksStickyChanged() {
        // didChangeText → delegate textDidChange is what drives updateContent.
        final class Spy: NSObject, NSTextViewDelegate { var count = 0; func textDidChange(_ n: Notification) { count += 1 } }
        let e = EditorHarness()
        let spy = Spy()
        e.textView.delegate = spy
        e.type("-")
        let before = spy.count
        e.type(" ")
        #expect(spy.count > before + 1)  // the space, then the conversion
    }

    // MARK: - Link detection rules

    @Test func detectsSchemesWwwAndEmail() {
        let links = StickyNSTextView.detectLinks(in: "a https://x.org/p, http://y.org www.apple.com mail me@ex.com")
        #expect(links.map(\.url.absoluteString) == ["https://x.org/p", "http://y.org", "https://www.apple.com", "mailto:me@ex.com"])
    }

    @Test func ignoresBareDomainsAndTrailingPunctuation() {
        #expect(StickyNSTextView.detectLinks(in: "see example.com and notes.txt").isEmpty)
        let ns = "See https://example.com. (https://x.org)" as NSString
        let ranges = StickyNSTextView.detectLinks(in: ns as String).map { ns.substring(with: $0.range) }
        #expect(ranges == ["https://example.com", "https://x.org"])
    }

    @Test func pastedURLBecomesLink() {
        let e = EditorHarness()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("visit https://paste.example.org/x now", forType: .string)
        e.textView.pasteAsPlainText(nil)
        #expect(e.html == #"<p>visit <a href="https://paste.example.org/x">https://paste.example.org/x</a> now</p>"#)
    }

    @Test func editingURLTextUpdatesLink() {
        let e = EditorHarness(html: #"<p><a href="https://example.com">https://example.com</a> end</p>"#)
        let ns = e.textView.string as NSString
        // Replace "com" with "org" inside the link.
        e.textView.setSelectedRange(ns.range(of: "com"))
        e.type("org")
        #expect(e.html == #"<p><a href="https://example.org/">https://example.org</a> end</p>"#)
    }

    @Test func editingCustomLinkTextKeepsTarget() {
        let e = EditorHarness(html: #"<p><a href="https://example.com/">click here</a></p>"#)
        let ns = e.textView.string as NSString
        e.textView.setSelectedRange(NSRange(location: ns.range(of: "here").location, length: 0))
        e.type("over ")
        #expect(e.html.contains(#"href="https://example.com/""#))
    }

    @Test func typedWwwBecomesHttpsLinkAndTypingAfterDoesNotExtend() async throws {
        let e = EditorHarness()
        e.type("see www.apple.com and example.com ")
        // Automatic detection runs asynchronously through NSSpellChecker.
        for _ in 0..<40 where !e.html.contains("<a ") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(e.html == #"<p>see <a href="https://www.apple.com/">www.apple.com</a> and example.com </p>"#)
        // Typing right at the end of the link stays outside it.
        let end = (e.textView.string as NSString).range(of: "www.apple.com").upperBound
        e.textView.setSelectedRange(NSRange(location: end, length: 0))
        e.type("x")
        #expect(e.html.contains(#"<a href="https://www.apple.com/">www.apple.com</a>x"#))
    }

    @Test func loadingDoesNotDetectLinks() {
        let e = EditorHarness(html: "<p>https://example.com</p>")
        #expect(e.html == "<p>https://example.com</p>")
    }
}

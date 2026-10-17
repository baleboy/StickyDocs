import SwiftUI
import AppKit

final class StickyNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": toggleBold(nil); return true
        case "i": toggleItalic(nil); return true
        case "u": toggleUnderline(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    @objc func toggleBold(_ sender: Any?) { applyTrait(.boldFontMask) }
    @objc func toggleItalic(_ sender: Any?) { applyTrait(.italicFontMask) }
    @objc func toggleUnderline(_ sender: Any?) { toggleUnderlineTrait() }

    private func applyTrait(_ trait: NSFontTraitMask) {
        let range = selectedRange()
        let fm = NSFontManager.shared

        func toggled(_ font: NSFont) -> NSFont {
            let has = fm.traits(of: font).contains(trait)
            return has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
        }

        if range.length == 0 {
            var attrs = typingAttributes
            let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            attrs[.font] = toggled(font)
            typingAttributes = attrs
            return
        }

        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            storage.addAttribute(.font, value: toggled(font), range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    private func toggleUnderlineTrait() {
        let range = selectedRange()
        if range.length == 0 {
            var attrs = typingAttributes
            let current = (attrs[.underlineStyle] as? Int) ?? 0
            attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            typingAttributes = attrs
            return
        }
        guard let storage = textStorage else { return }
        let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        let newValue: Int = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        storage.beginEditing()
        storage.addAttribute(.underlineStyle, value: newValue, range: range)
        storage.endEditing()
        didChangeText()
    }

    // MARK: - Lists

    enum ListStyle { case bullet, numbered }

    // The Markdown-style list shortcut for what's been typed at the start of
    // a paragraph just before a space, if any. Only "1" starts a numbered
    // list, so "2. " or "10. " in prose stays prose.
    nonisolated static func listShortcut(forParagraphPrefix prefix: String) -> ListStyle? {
        switch prefix {
        case "-", "*": return .bullet
        case "1.", "1)": return .numbered
        default: return nil
        }
    }

    @objc func toggleBulletList(_ sender: Any?) { toggleList(.bullet) }
    @objc func toggleNumberedList(_ sender: Any?) { toggleList(.numbered) }

    // Format menu: applies the list to every paragraph the selection touches,
    // or removes it if they're all already that kind of list.
    private func toggleList(_ style: ListStyle) {
        guard let storage = textStorage else { return }
        let ns = storage.string as NSString
        let span = ns.paragraphRange(for: selectedRange())
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: span, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            paragraphs.append(enclosing)
        }
        if paragraphs.isEmpty { paragraphs = [span] }
        let wantOrdered = style == .numbered
        let alreadyApplied = paragraphs.allSatisfy {
            HTMLNormalizer.isOrderedList(storage.attributedSubstring(from: $0)) == wantOrdered
        }
        replaceParagraphs(paragraphs, with: alreadyApplied ? nil : style, cursorAfterMarker: false)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let start = replacementRange.location != NSNotFound ? replacementRange.location : selectedRange().location
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        guard !hasMarkedText(), let typed else { return }
        if typed.count == 1, typed.first!.isWhitespace, !insertingTrigger { wordEnded(at: start) }
        if typed == " " { convertListShortcutIfNeeded() }
    }

    override func insertNewline(_ sender: Any?) {
        let start = selectedRange().location
        insertingTrigger = true
        super.insertNewline(sender)
        insertingTrigger = false
        wordEnded(at: start)
    }

    override func insertTab(_ sender: Any?) {
        let start = selectedRange().location
        // Tab accepts a previewed date shortcut, like an inline completion:
        // the keyword expands and no tab is inserted.
        if let hint = dateHint, start == NSMaxRange(hint.range), expandDateShortcutIfNeeded(endingAt: start) { return }
        insertingTrigger = true
        super.insertTab(sender)
        insertingTrigger = false
        wordEnded(at: start)
    }

    // Set while Return or Tab is inserted, in case AppKit routes it through
    // insertText, so the word before it is handled once, from the right spot.
    private var insertingTrigger = false

    // A space, Tab or Return was just inserted at `location`: expand a date
    // shortcut typed before it, or else link a URL typed before it.
    private func wordEnded(at location: Int) {
        if !expandDateShortcutIfNeeded(endingAt: location) { linkURLBeforeIfNeeded(at: location) }
    }

    // MARK: - Date shortcuts

    // Replaces an "@today"-style keyword ending at `location` with its value,
    // as its own undo step, so ⌘Z right after brings back the keyword.
    private func expandDateShortcutIfNeeded(endingAt location: Int) -> Bool {
        guard let (token, value) = dateShortcut(endingAt: location), let storage = textStorage else { return false }
        breakUndoCoalescing()
        // The trigger and the expansion arrive in the same event, so they'd
        // share one undo group; close it so ⌘Z undoes only the expansion.
        if let undoManager, undoManager.groupingLevel == 1 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        guard shouldChangeText(in: token.range, replacementString: value) else { return false }
        let cursor = selectedRange()
        var attributes = storage.attributes(at: token.range.location, effectiveRange: nil)
        attributes[.link] = nil
        storage.replaceCharacters(in: token.range, with: NSAttributedString(string: value, attributes: attributes))
        didChangeText()
        let delta = (value as NSString).length - token.range.length
        if cursor.location >= NSMaxRange(token.range) {
            setSelectedRange(NSRange(location: cursor.location + delta, length: cursor.length))
        }
        breakUndoCoalescing()
        return true
    }

    // The shortcut ending at `location` that would expand, with its value:
    // not inside a link and not dismissed with Esc.
    private func dateShortcut(endingAt location: Int) -> (token: (range: NSRange, keyword: String), value: String)? {
        guard let storage = textStorage,
              let token = DateShortcut.token(endingAt: location, in: storage.string as NSString),
              token.range != declinedDateShortcut,
              let value = DateShortcut.expansion(for: token.keyword)
        else { return nil }
        var linked = false
        storage.enumerateAttribute(.link, in: token.range) { value, _, stop in
            if value != nil { linked = true; stop.pointee = true }
        }
        return linked ? nil : (token, value)
    }

    // While the cursor sits right after a shortcut that would expand, the
    // keyword is tinted and its value previewed in grey after the cursor.
    // Both are display-only (a temporary attribute and a label), so they
    // never reach the text, undo or sync.
    private(set) var dateHint: (range: NSRange, value: String)?
    private lazy var dateHintLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.textColor = NSColor.black.withAlphaComponent(0.4)
        label.lineBreakMode = .byClipping
        label.isHidden = true
        addSubview(label)
        return label
    }()
    var isDateHintPreviewVisible: Bool { dateHint != nil && !dateHintLabel.isHidden }

    // A shortcut dismissed with Esc: it stays literal text until an edit
    // touches it. Positions only, kept while the text view lives.
    private var declinedDateShortcut: NSRange?
    private var windowIsKey = true

    private func updateDateHint() {
        guard let layoutManager, let textContainer, let storage = textStorage else { return }
        if dateHint != nil {
            dateHint = nil
            dateHintLabel.isHidden = true
            // The whole text, since edits may have moved the old range.
            layoutManager.removeTemporaryAttribute(.backgroundColor,
                                                   forCharacterRange: NSRange(location: 0, length: storage.length))
        }
        let cursor = selectedRange()
        let ns = storage.string as NSString
        // Not when the keyword runs straight into a word ("@today|ok").
        let wordFollows = cursor.location < ns.length
            && Unicode.Scalar(ns.character(at: cursor.location)).map(CharacterSet.alphanumerics.contains) == true
        guard windowIsKey, window?.firstResponder === self, cursor.length == 0, !wordFollows,
              let (token, value) = dateShortcut(endingAt: cursor.location) else { return }
        dateHint = (token.range, value)
        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.1),
                                            forCharacterRange: token.range)
        // The preview would cover any text after the cursor, so it only
        // shows at the end of a line; the tint alone marks it elsewhere.
        guard cursor.location == ns.length || ns.character(at: cursor.location) == 0x0A else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let font = storage.attribute(.font, at: token.range.location, effectiveRange: nil) as? NSFont
            ?? NSFont.systemFont(ofSize: 14)
        dateHintLabel.font = font
        dateHintLabel.stringValue = value
        let size = dateHintLabel.fittingSize
        let x = textContainerOrigin.x + rect.maxX + 4
        let width = min(size.width, bounds.maxX - textContainerInset.width - x)
        guard width >= 12 else { return }
        dateHintLabel.frame = NSRect(x: x, y: textContainerOrigin.y + rect.maxY - size.height,
                                     width: width, height: size.height)
        dateHintLabel.isHidden = false
    }

    // Esc while a hint shows dismisses it: the keyword stays as typed, and
    // the next space doesn't expand it. Otherwise Esc does what it always did.
    override func cancelOperation(_ sender: Any?) {
        guard let hint = dateHint else { return super.cancelOperation(sender) }
        declinedDateShortcut = hint.range
        updateDateHint()
    }

    // Keeps the dismissed shortcut's range in step with edits before it, and
    // forgets it once an edit lands inside it.
    private func adjustDeclinedDateShortcut(for edit: NSRange, replacement: String?) {
        guard let declined = declinedDateShortcut else { return }
        let delta = ((replacement ?? "") as NSString).length - edit.length
        if NSMaxRange(edit) <= declined.location {
            declinedDateShortcut = NSRange(location: declined.location + delta, length: declined.length)
        } else if edit.location >= NSMaxRange(declined) {
            return
        } else {
            declinedDateShortcut = nil
        }
    }

    override func becomeFirstResponder() -> Bool {
        defer { updateDateHint() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { updateDateHint() }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged(_:)),
                                               name: NSWindow.didResignKeyNotification, object: window)
    }

    @objc private func windowKeyChanged(_ notification: Notification) {
        windowIsKey = notification.name == NSWindow.didBecomeKeyNotification
        updateDateHint()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if dateHint != nil { updateDateHint() }  // rewrapped: move the preview
    }

    // Runs after the space is inserted, as its own undo step, so ⌘Z right
    // after the conversion brings back the literal "- " as plain text.
    // Paste doesn't go through insertText, so pasted markers stay text.
    private func convertListShortcutIfNeeded() {
        guard let storage = textStorage else { return }
        let cursor = selectedRange()
        guard cursor.length == 0 else { return }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: cursor.location, length: 0))
        let prefix = ns.substring(with: NSRange(location: paragraph.location, length: cursor.location - paragraph.location))
        guard prefix.hasSuffix(" "),
              let style = Self.listShortcut(forParagraphPrefix: String(prefix.dropLast())),
              HTMLNormalizer.isOrderedList(storage.attributedSubstring(from: paragraph)) == nil
        else { return }
        breakUndoCoalescing()
        // The space and the conversion arrive in the same event, so they'd
        // share one undo group; close it so ⌘Z undoes only the conversion.
        if let undoManager, undoManager.groupingLevel == 1 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        replaceParagraphs([paragraph], with: style, removingPrefix: (prefix as NSString).length, cursorAfterMarker: true)
        breakUndoCoalescing()
    }

    // Backspace right after a list item's marker turns the item back into a
    // plain paragraph, keeping its text. (NSTextView on its own deletes the
    // marker characters but leaves the paragraph's list style behind.)
    override func deleteBackward(_ sender: Any?) {
        if let storage = textStorage, selectedRange().length == 0 {
            let cursor = selectedRange().location
            let ns = storage.string as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            if HTMLNormalizer.isOrderedList(storage.attributedSubstring(from: paragraph)) != nil,
               cursor <= paragraph.location + Self.markerLength(in: ns.substring(with: paragraph)) {
                replaceParagraphs([paragraph], with: nil, cursorAfterMarker: true)
                return
            }
        }
        super.deleteBackward(sender)
    }

    // Length of the "\t⦁\t" / "\t1\t" marker text TextKit 1 keeps at the
    // start of each list item.
    private static func markerLength(in paragraph: String) -> Int {
        guard let match = paragraph.range(of: #"^\t[^\t\n]*\t"#, options: .regularExpression) else { return 0 }
        return (String(paragraph[match]) as NSString).length
    }

    // Rewrites consecutive paragraphs (each range including its terminator)
    // as items of one new list, or as plain paragraphs when `style` is nil,
    // in a single undoable change. The result matches what HTMLNormalizer
    // produces for <ul>/<ol> content, so lists made here and lists loaded
    // from HTML serialize and push identically.
    private func replaceParagraphs(_ paragraphs: [NSRange], with style: ListStyle?,
                                   removingPrefix prefixLength: Int = 0, cursorAfterMarker: Bool) {
        guard let storage = textStorage, let first = paragraphs.first, let last = paragraphs.last else { return }
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let list = style.map { NSTextList(markerFormat: $0 == .bullet ? HTMLNormalizer.bulletMarkerFormat : .decimal, options: 0) }
        let result = NSMutableAttributedString()
        var cursor = span.location
        for (index, paragraph) in paragraphs.enumerated() {
            let text = storage.attributedSubstring(from: paragraph)
            let existingMarker = HTMLNormalizer.isOrderedList(text) != nil ? Self.markerLength(in: text.string) : 0
            let skip = min(text.length, max(existingMarker, prefixLength))
            let body = NSMutableAttributedString(attributedString: text.attributedSubstring(
                from: NSRange(location: skip, length: text.length - skip)))
            var markerAttrs = body.length > 0 ? body.attributes(at: 0, effectiveRange: nil) : typingAttributes
            markerAttrs[.link] = nil
            let item = NSMutableAttributedString()
            if let list {
                item.append(NSAttributedString(string: "\t\(list.marker(forItemNumber: index + 1))\t", attributes: markerAttrs))
            }
            item.append(body)
            if item.length == 0 { item.append(NSAttributedString(string: "", attributes: markerAttrs)) }
            let whole = NSRange(location: 0, length: item.length)
            item.removeAttribute(HTMLNormalizer.orderedKey, range: whole)
            let paragraphStyle = list.map { HTMLNormalizer.listParagraphStyle([$0]) } ?? NSParagraphStyle()
            if style == .numbered { item.addAttribute(HTMLNormalizer.orderedKey, value: true, range: whole) }
            item.addAttribute(.paragraphStyle, value: paragraphStyle, range: whole)
            if index == 0 { cursor = span.location + item.length - body.length }
            result.append(item)
        }
        guard shouldChangeText(in: span, replacementString: result.string) else { return }
        linkUnderEdit = nil  // links move with their text here; nothing to re-derive
        storage.replaceCharacters(in: span, with: result)
        didChangeText()
        if cursorAfterMarker {
            setSelectedRange(NSRange(location: cursor, length: 0))
        } else {
            setSelectedRange(NSRange(location: span.location, length: result.length - (result.string.hasSuffix("\n") ? 1 : 0)))
        }
        // An empty item has no characters to carry its style; seed typing
        // attributes so the first keystroke lands inside the list.
        if result.length > 0 {
            typingAttributes = result.attributes(at: min(cursor - span.location, result.length - 1), effectiveRange: nil)
                .filter { $0.key != .link }
        }
    }

    // MARK: - Links

    // Only explicit URLs (scheme or "www.") and email addresses become links;
    // the data detector would otherwise also link bare names like
    // "notes.txt" or "example.com".
    nonisolated static func acceptedLink(for text: String, detected url: URL) -> URL? {
        let lower = text.lowercased()
        switch url.scheme?.lowercased() {
        case "mailto":
            return url
        case "http", "https":
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return url }
            if lower.hasPrefix("www.") { return URL(string: "https://" + text) }
            return nil
        default:
            return nil
        }
    }

    // All links detected in `text`, filtered and normalized as above.
    nonisolated static func detectLinks(in text: String) -> [(range: NSRange, url: URL)] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let ns = text as NSString
        return detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard let url = match.url,
                  let accepted = acceptedLink(for: ns.substring(with: match.range), detected: url) else { return nil }
            return (match.range, accepted)
        }
    }

    var detectsLinks = true

    // Links the URL typed just before `location`, where a space, tab or
    // Return was inserted, as its own undo step. Done here rather than with
    // AppKit's automatic link detection, which re-checks unchecked text from
    // the start of the document through the spell checker and, on some
    // longer loaded notes, never delivers a result.
    private func linkURLBeforeIfNeeded(at location: Int) {
        guard detectsLinks, let storage = textStorage, location > 0, location <= storage.length else { return }
        let ns = storage.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: location - 1, length: 0))
        let before = NSRange(location: paragraph.location, length: location - paragraph.location)
        let text = ns.substring(with: before)
        // Only the word just typed: an older plain URL in the same paragraph
        // (say, one the user unlinked) is left alone.
        guard let link = Self.detectLinks(in: text).last,
              !(text as NSString).substring(from: NSMaxRange(link.range)).contains(where: \.isWhitespace)
        else { return }
        let range = NSRange(location: before.location + link.range.location, length: link.range.length)
        var linked = false
        storage.enumerateAttribute(.link, in: range) { value, _, stop in
            if value != nil { linked = true; stop.pointee = true }
        }
        guard !linked else { return }
        breakUndoCoalescing()
        // The space and the link arrive in the same event, so they'd share
        // one undo group; close it so ⌘Z undoes only the link.
        if let undoManager, undoManager.groupingLevel == 1 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.link, value: link.url, range: range)
        didChangeText()
        breakUndoCoalescing()
    }

    // Run detection over pasted text too, leaving any links the pasted rich
    // text already carried.
    override func paste(_ sender: Any?) { detectingLinks { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { detectingLinks { super.pasteAsPlainText(sender) } }
    override func pasteAsRichText(_ sender: Any?) { detectingLinks { super.pasteAsRichText(sender) } }

    private func detectingLinks(_ paste: () -> Void) {
        let start = selectedRange().location
        paste()
        let end = selectedRange().location
        guard detectsLinks, end > start, let storage = textStorage else { return }
        let pasted = NSRange(location: start, length: end - start)
        let links = Self.detectLinks(in: (storage.string as NSString).substring(with: pasted)).filter { link in
            let range = NSRange(location: start + link.range.location, length: link.range.length)
            var found = false
            storage.enumerateAttribute(.link, in: range) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return !found
        }
        guard !links.isEmpty, shouldChangeText(in: pasted, replacementString: nil) else { return }
        for link in links {
            storage.addAttribute(.link, value: link.url,
                                 range: NSRange(location: start + link.range.location, length: link.range.length))
        }
        didChangeText()
    }

    // When an edit lands inside a link whose text is its own URL, the link
    // is re-derived from the edited text afterwards (updated, or removed if
    // the text no longer reads as a URL). Links with other text, e.g.
    // "click here" from Docs, are left alone.
    private var linkUnderEdit: (region: NSRange, delta: Int)?
    // Where the cursor sat after the last such edit. Typing on from there
    // (select "com", type "org") keeps editing the link, even though each
    // later keystroke lands at the link's end.
    private var linkEditCursor: Int?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if let cursor = linkEditCursor, ranges.count != 1 || ranges[0].rangeValue != NSRange(location: cursor, length: 0) {
            linkEditCursor = nil
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateDateHint()
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        adjustDeclinedDateShortcut(for: affectedCharRange, replacement: replacementString)
        linkUnderEdit = nil
        let continuing = linkEditCursor
        linkEditCursor = nil
        guard let replacement = replacementString, let storage = textStorage else { return true }
        let probe: Int
        if affectedCharRange.length > 0 {
            probe = affectedCharRange.location
        } else {
            probe = affectedCharRange.location - 1  // insertion: look at the char before
        }
        guard probe >= 0, probe < storage.length else { return true }
        var linkRange = NSRange()
        guard let url = HTMLNormalizer.allowedLink(storage.attribute(.link, at: probe, longestEffectiveRange: &linkRange,
                                                                     in: NSRange(location: 0, length: storage.length))),
              Self.text((storage.string as NSString).substring(with: linkRange), isURL: url)
        else { return true }
        // Typing at either edge of a link doesn't change the link's text.
        if affectedCharRange.length == 0, continuing != affectedCharRange.location,
           affectedCharRange.location <= linkRange.location || affectedCharRange.location >= NSMaxRange(linkRange) {
            return true
        }
        let start = min(linkRange.location, affectedCharRange.location)
        let end = max(NSMaxRange(linkRange), NSMaxRange(affectedCharRange))
        linkUnderEdit = (NSRange(location: start, length: end - start),
                         (replacement as NSString).length - affectedCharRange.length)
        return true
    }

    override func didChangeText() {
        if let edit = linkUnderEdit, let storage = textStorage {
            linkUnderEdit = nil
            let region = NSRange(location: edit.region.location, length: max(0, edit.region.length + edit.delta))
            if NSMaxRange(region) <= storage.length {
                let text = (storage.string as NSString).substring(with: region)
                storage.removeAttribute(.link, range: region)
                for link in Self.detectLinks(in: text) {
                    storage.addAttribute(.link, value: link.url,
                                         range: NSRange(location: region.location + link.range.location, length: link.range.length))
                }
                typingAttributes[.link] = nil
                linkEditCursor = NSMaxRange(region)
            }
        }
        super.didChangeText()
        updateDateHint()
    }

    // Whether a link's visible text is just its URL, as for detected links.
    nonisolated static func text(_ text: String, isURL url: URL) -> Bool {
        func trimmed(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        let target = trimmed(url.absoluteString.lowercased())
        let lower = trimmed(text.lowercased())
        return [lower, "https://" + lower, "http://" + lower, "mailto:" + lower].contains(target)
    }

    private func link(at event: NSEvent) -> (url: URL, range: NSRange)? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(point)
        else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        guard let url = HTMLNormalizer.allowedLink(storage.attribute(.link, at: index, longestEffectiveRange: &range,
                                                                     in: NSRange(location: 0, length: storage.length)))
        else { return nil }
        return (url, range)
    }

    private var contextLink: (url: URL, range: NSRange)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        contextLink = link(at: event)
        guard contextLink != nil else { return menu }
        // Replace AppKit's own link items so they aren't listed twice.
        let builtIn: Set<String> = ["Open Link", "Copy Link", "Edit Link…", "Remove Link"]
        for item in menu.items where builtIn.contains(item.title) { menu.removeItem(item) }
        let items = [
            NSMenuItem(title: "Open Link", action: #selector(openContextLink(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Copy Link", action: #selector(copyContextLink(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Remove Link", action: #selector(removeContextLink(_:)), keyEquivalent: ""),
            .separator()
        ]
        for (i, item) in items.enumerated() {
            item.target = self
            menu.insertItem(item, at: i)
        }
        return menu
    }

    @objc private func openContextLink(_ sender: Any?) {
        guard let url = contextLink?.url else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyContextLink(_ sender: Any?) {
        guard let url = contextLink?.url else { return }
        let string = url.scheme == "mailto" ? String(url.absoluteString.dropFirst("mailto:".count)) : url.absoluteString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @objc private func removeContextLink(_ sender: Any?) {
        guard let range = contextLink?.range, let storage = textStorage, NSMaxRange(range) <= storage.length,
              shouldChangeText(in: range, replacementString: nil) else { return }
        storage.removeAttribute(.link, range: range)
        didChangeText()
    }
}

// Lets the owner push content into the live NSTextView immediately,
// bypassing updateNSView's skip-while-focused rule. Used for content the
// engine replaced (pull, restore backup) — as opposed to store updates that
// merely echo the user's own typing back, which must not clobber the editor.
@MainActor
final class EditorContentSink {
    var apply: ((String) -> Void)?
}

struct StickyTextEditor: NSViewRepresentable {
    // Bound to the sticky's current HTML. Re-applied by updateNSView when the
    // store changes underneath us, so long as the user isn't actively typing
    // in this text view. Engine-originated replacements arrive through
    // `externalContent` instead and apply even while typing.
    let html: String
    let externalContent: EditorContentSink
    let onChange: (NSAttributedString) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let textView = StickyNSTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        // StickyNSTextView detects links itself (see linkURLBeforeIfNeeded).
        textView.isAutomaticLinkDetectionEnabled = false
        // Display-only: link styling isn't stored as underline/color in the
        // text, so it never becomes <u> in the synced HTML.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand
        ]
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 0)
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let initialAttr = HTMLNormalizer.attributedString(from: html)
        textView.textStorage?.setAttributedString(initialAttr)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        externalContent.apply = { [weak coordinator = context.coordinator] html in
            coordinator?.applyExternal(html)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        // Don't clobber while the user is actively typing in this field.
        // (Window-key + first-responder is the precise check — we want
        // Sync Now triggered from the menu bar, which steals key, to still
        // refresh a sticky the user was looking at.)
        if textView.window?.isKeyWindow == true,
           textView.window?.firstResponder === textView {
            return
        }
        let currentHTML = HTMLNormalizer.html(from: NSAttributedString(attributedString: storage))
        if currentHTML == html { return }
        let newAttr = HTMLNormalizer.attributedString(from: html)
        storage.setAttributedString(newAttr)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        let onChange: (NSAttributedString) -> Void

        init(onChange: @escaping (NSAttributedString) -> Void) {
            self.onChange = onChange
        }

        func applyExternal(_ html: String) {
            guard let textView, let storage = textView.textStorage else { return }
            if HTMLNormalizer.html(from: NSAttributedString(attributedString: storage)) == html { return }
            let selection = textView.selectedRange()
            storage.setAttributedString(HTMLNormalizer.attributedString(from: html))
            let length = storage.length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            onChange(NSAttributedString(attributedString: storage))
        }
    }
}

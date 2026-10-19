import Foundation
import AppKit

// Canonical HTML <-> NSAttributedString conversion for the supported feature set:
// bold, italic, underline, bulleted and numbered lists (nested too), and http/https/mailto
// links.
//
// The serializer emits a minimal, deterministic HTML subset.
// The parser accepts arbitrary HTML (including Drive's verbose export),
// canonicalizes the resulting NSAttributedString to only carry the
// attributes we care about, and discards everything else (font family,
// size, color, alignment, indent, etc).
//
// Links never carry underline. Both AppKit's HTML import and Docs' export
// underline link text as link styling, and the two are indistinguishable
// from an explicit underline — keeping it would turn every pulled link into
// <u> formatting that then gets pushed back.
//
// Both directions run on the main actor because NSAttributedString's
// HTML import is documented to require the main thread.
enum HTMLNormalizer {

    // MARK: - NSAttributedString -> canonical HTML

    @MainActor
    static func html(from attributed: NSAttributedString) -> String {
        let length = attributed.length
        guard length > 0 else { return "" }
        let nsString = attributed.string as NSString

        var html = ""
        var items: [(path: [Bool], body: String)] = []
        nsString.enumerateSubstrings(
            in: NSRange(location: 0, length: length),
            options: .byParagraphs
        ) { _, paragraphRange, _, _ in
            let para = attributed.attributedSubstring(from: paragraphRange)
            if let path = Self.listPath(para) {
                items.append((path, serializeInline(trimListMarker(para, ordered: path.last!))))
            } else {
                html += listHTML(items)
                items = []
                html += "<p>" + serializeInline(para) + "</p>"
            }
        }
        return html + listHTML(items)
    }

    // Markup for a run of consecutive list items, each given by its path of
    // list kinds (true = numbered), outermost first. An item one level deeper
    // than the one before it opens a list inside that item, as <ul>/<ol>
    // nest in HTML.
    private static func listHTML(_ items: [(path: [Bool], body: String)]) -> String {
        var html = ""
        var open: [Bool] = []
        func closeList() { html += "</li></\(open.removeLast() ? "ol" : "ul")>" }
        for item in items {
            var shared = 0
            while shared < min(open.count, item.path.count), open[shared] == item.path[shared] { shared += 1 }
            while open.count > shared { closeList() }
            if shared == item.path.count {
                html += "</li>"
            } else {
                for ordered in item.path[shared...] {
                    html += ordered ? "<ol>" : "<ul>"
                    open.append(ordered)
                }
            }
            html += "<li>" + item.body
        }
        while !open.isEmpty { closeList() }
        return html
    }

    static let numberedMarkerFormats: Set<NSTextList.MarkerFormat> = [
        .decimal, .lowercaseAlpha, .uppercaseAlpha, .lowercaseLatin, .uppercaseLatin,
        .lowercaseRoman, .uppercaseRoman, .lowercaseHexadecimal, .uppercaseHexadecimal, .octal
    ]

    // nil when the paragraph isn't a list item; otherwise whether each level
    // of its list nesting is numbered, outermost first (a nested item made
    // with Tab carries its parents' lists as well as its own).
    // `orderedKey` (stamped from the raw HTML scan) is authoritative for
    // imported content, whose marker format can't be trusted. Lists made in
    // the editor carry a numeric marker format instead, which also survives
    // NSTextView continuing the list onto a new item when Return is pressed.
    static func listPath(_ paragraph: NSAttributedString) -> [Bool]? {
        guard paragraph.length > 0 else { return nil }
        let range = NSRange(location: 0, length: paragraph.length)
        var lists: [NSTextList]?
        paragraph.enumerateAttribute(.paragraphStyle, in: range) { value, _, stop in
            if let style = value as? NSParagraphStyle, !style.textLists.isEmpty {
                lists = style.textLists
                stop.pointee = true
            }
        }
        guard let lists else { return nil }
        var stamped: [Bool] = []
        paragraph.enumerateAttribute(orderedKey, in: range) { value, _, stop in
            if let path = value as? [Bool] { stamped = path; stop.pointee = true }
            else if (value as? Bool) == true { stamped = [true]; stop.pointee = true }
        }
        return lists.indices.map { i in
            i < stamped.count ? stamped[i] : numberedMarkerFormats.contains(lists[i].markerFormat)
        }
    }

    // nil when the paragraph isn't a list item; otherwise whether the item
    // itself (its innermost list) is numbered.
    static func isOrderedList(_ paragraph: NSAttributedString) -> Bool? {
        listPath(paragraph)?.last
    }

    // Apple's HTML parser includes the rendered list marker (e.g. "\t•\t" or
    // "\t1.\t") as plain text inside each list-item paragraph, and the editor
    // writes one the same way, at every nesting level ("\t⁃\t" for a nested
    // bullet). We must strip it before serializing, otherwise the next parse
    // would render the marker again on top of the literal text, doubling it.
    //
    // Google's HTML export uses CSS counters and does not include the marker
    // in the text, but does add leading whitespace for indentation. So the
    // marker char is optional in the fallback - the whitespace alone matches.
    static func trimListMarker(_ paragraph: NSAttributedString, ordered: Bool) -> NSAttributedString {
        let marker = ordered ? #"\d+[.)]?"# : #"[•⦁·▪◦◯●○■□⁃‣*-]"#
        let pattern = #"^\t[^\t\n]*\t\s*|^\s*("# + marker + #"\s*)?"#
        let text = paragraph.string as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: paragraph.string, range: NSRange(location: 0, length: text.length)),
              match.range.location == 0
        else { return paragraph }
        let start = match.range.upperBound
        if start >= paragraph.length { return NSAttributedString(string: "") }
        return paragraph.attributedSubstring(from: NSRange(location: start, length: paragraph.length - start))
    }

    private static func serializeInline(_ paragraph: NSAttributedString) -> String {
        var out = ""
        paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) { attrs, range, _ in
            let raw = (paragraph.string as NSString).substring(with: range)
            let text = raw.replacingOccurrences(of: "\n", with: "")
            guard !text.isEmpty else { return }

            var bold = false
            var italic = false
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                bold = traits.contains(.bold)
                italic = traits.contains(.italic)
            }
            let link = allowedLink(attrs[.link])
            let underline: Bool = {
                if link != nil { return false }
                if let n = attrs[.underlineStyle] as? Int { return n != 0 }
                if let n = attrs[.underlineStyle] as? NSNumber { return n.intValue != 0 }
                return false
            }()

            var open = ""
            var close = ""
            if let link { open += "<a href=\"\(escapeAttribute(link.absoluteString))\">"; close = "</a>" + close }
            if bold { open += "<b>"; close = "</b>" + close }
            if italic { open += "<i>"; close = "</i>" + close }
            if underline { open += "<u>"; close = "</u>" + close }

            out += open + escape(text) + close
        }
        return out
    }

    private static func escape(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        return r
    }

    private static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // Bulleted lists use "⦁" (Z notation spot) rather than the system's
    // "•", which reads as too small at sticky text sizes. It's a literal
    // marker format, so NSTextView repeats it on each new item.
    static let bulletMarkerFormat = NSTextList.MarkerFormat("⦁")

    // Display style for list items. TextKit 1 keeps each item's marker as
    // "\t•\t" text, so with default 28pt tab stops the bullet sits at 28pt
    // and the text at 56pt. Tight stops plus a matching hanging indent keep
    // wrapped lines aligned with the text; numbered lists get a little more
    // room so two-digit numbers fit. A nested item (Tab in a list item, where
    // AppKit's own style steps 36pt per level) starts its marker where its
    // parent's text starts, so each level is as compact as the first.
    // Display only: indents and tabs never reach the canonical HTML.
    static func listParagraphStyle(_ lists: [NSTextList]) -> NSParagraphStyle {
        let bulletFormats: Set<NSTextList.MarkerFormat> = [bulletMarkerFormat, .disc, .circle, .square, .hyphen]
        let widths = lists.map { CGFloat(bulletFormats.contains($0.markerFormat) ? 16 : 22) }
        let base = widths.dropLast().reduce(0, +)
        let textStart = base + (widths.last ?? 16)
        let style = NSMutableParagraphStyle()
        style.textLists = lists
        style.tabStops = [NSTextTab(textAlignment: .natural, location: base + 4),
                          NSTextTab(textAlignment: .natural, location: textStart)]
        style.defaultTabInterval = widths.last ?? 16
        style.headIndent = textStart
        return style
    }

    // MARK: - Links

    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    // Normalizes a `.link` attribute value (URL or String) to a URL we keep,
    // or nil. Drive's HTML export routes every link through a
    // https://www.google.com/url?q=<target>&sa=D&... redirect, which is
    // unwrapped back to the real target. An empty http(s) path becomes "/",
    // as AppKit's HTML import does, so a URL reads the same before and after
    // a parse.
    static func allowedLink(_ value: Any?) -> URL? {
        let url: URL?
        switch value {
        case let u as URL: url = u
        case let s as String: url = URL(string: s)
        default: url = nil
        }
        guard var url else { return nil }
        if let host = url.host?.lowercased(), host == "www.google.com" || host == "google.com",
           url.path == "/url",
           let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "q" })?.value,
           let target = URL(string: q) {
            url = target
        }
        guard let scheme = url.scheme?.lowercased(), allowedLinkSchemes.contains(scheme) else { return nil }
        if scheme != "mailto", var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           comps.path.isEmpty, comps.host != nil {
            comps.path = "/"
            url = comps.url ?? url
        }
        return url
    }

    // MARK: - HTML -> canonical NSAttributedString

    // NSAttributedString's HTML parser loses the <ol>-vs-<ul> distinction when
    // the source uses CSS counters (as Google Drive's export does). We pre-scan
    // the raw HTML for <ol>/<ul>/<li> structure, then tag list-item paragraphs
    // with this custom attribute after canonicalization. Its value is the
    // item's path of list kinds as `[Bool]` (see `listPath`); the editor
    // stamps a plain `true` on the numbered items it makes.
    static let orderedKey = NSAttributedString.Key("com.balenet.StickyDocs.ordered")

    private static func scanListItemOrderedPaths(_ html: String) -> [[Bool]] {
        var stack: [Bool] = []
        var paths: [[Bool]] = []
        guard let regex = try? NSRegularExpression(pattern: #"<(/?)(ol|ul|li)[^>]*>"#, options: [.caseInsensitive]) else {
            return paths
        }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let isClose = ns.substring(with: match.range(at: 1)) == "/"
            let tag = ns.substring(with: match.range(at: 2)).lowercased()
            switch (tag, isClose) {
            case ("ol", false): stack.append(true)
            case ("ul", false): stack.append(false)
            case ("ol", true), ("ul", true): _ = stack.popLast()
            case ("li", false): paths.append(stack.isEmpty ? [false] : stack)
            default: break
            }
        }
        return paths
    }

    // Drive's HTML export doesn't nest lists: every run of items at one
    // level is its own top-level <ul>/<ol>, with the level only in a class
    // ("lst-kix_<list id>-<level>") and the indent in CSS. Rebuild each run
    // of adjacent such lists that has nested items as nested HTML, so the
    // parser sees the structure `html(from:)` writes.
    static func nestDocsExportLists(_ html: String) -> String {
        guard html.contains("lst-kix_"),
              let listRegex = try? NSRegularExpression(
                pattern: #"<(ul|ol)\b[^>]*\blst-kix_\w+-(\d+)\b[^>]*>(.*?)</\1\s*>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let itemRegex = try? NSRegularExpression(
                pattern: #"<li\b[^>]*>(.*?)</li\s*>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return html }

        let ns = html as NSString
        var out = ""
        var cursor = 0
        var run: [(level: Int, ordered: Bool, body: String)] = []
        var runSource = ""
        func flush() {
            if run.contains(where: { $0.level > 0 }) {
                var items: [(path: [Bool], body: String)] = []
                var path: [Bool] = []
                for item in run {
                    // A level's kind comes from the item before it at that
                    // level, or from this item when it skips levels.
                    path = Array(path.prefix(item.level))
                    while path.count < item.level { path.append(item.ordered) }
                    path.append(item.ordered)
                    items.append((path, item.body))
                }
                out += listHTML(items)
            } else {
                out += runSource
            }
            run = []
            runSource = ""
        }
        for match in listRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flush()
                out += gap
            } else {
                runSource += gap
            }
            let ordered = ns.substring(with: match.range(at: 1)).lowercased() == "ol"
            let level = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let inner = ns.substring(with: match.range(at: 3))
            let innerNS = inner as NSString
            for item in itemRegex.matches(in: inner, range: NSRange(location: 0, length: innerNS.length)) {
                run.append((level, ordered, innerNS.substring(with: item.range(at: 1))))
            }
            runSource += ns.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        flush()
        return out + ns.substring(from: cursor)
    }

    @MainActor
    static func attributedString(from html: String) -> NSAttributedString {
        let html = nestDocsExportLists(html)
        guard !html.isEmpty, let data = html.data(using: .utf8) else {
            return NSAttributedString(string: "")
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let raw = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return NSAttributedString(string: "")
        }
        let canonical = canonicalize(raw)
        let paths = scanListItemOrderedPaths(html)
        return tagOrderedListItems(canonical, orderedPaths: paths)
    }

    // Walk paragraphs of the canonical attributed string. For each paragraph
    // that is a list item (has textLists set in its paragraphStyle), consume
    // the next path and stamp it as `orderedKey` if any level is numbered.
    private static func tagOrderedListItems(_ attr: NSAttributedString, orderedPaths: [[Bool]]) -> NSAttributedString {
        guard !orderedPaths.isEmpty else { return attr }
        let mutable = NSMutableAttributedString(attributedString: attr)
        let ns = mutable.string as NSString
        var flagIdx = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, paragraphRange, _, _ in
            // Determine whether this paragraph has textLists set anywhere.
            var hasList = false
            mutable.enumerateAttribute(.paragraphStyle, in: paragraphRange) { value, _, stop in
                if let style = value as? NSParagraphStyle, !style.textLists.isEmpty {
                    hasList = true
                    stop.pointee = true
                }
            }
            guard hasList else { return }
            guard flagIdx < orderedPaths.count else { return }
            let path = orderedPaths[flagIdx]
            flagIdx += 1
            if path.contains(true) {
                mutable.addAttribute(orderedKey, value: path, range: paragraphRange)
            }
        }
        return mutable
    }

    private static func canonicalize(_ raw: NSAttributedString) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()
        // Imported bulleted lists get the editor's bullet glyphs: ours at the
        // top level, and the hyphen NSTextView gives a list nested with Tab
        // below it. One replacement per source list, so items stay in the
        // same list.
        var bulletLists: [ObjectIdentifier: NSTextList] = [:]
        let importedBullets: Set<NSTextList.MarkerFormat> = [.disc, .circle, .square]
        let importedBulletMarkers: Set<String> = ["\t•\t", "\t◦\t", "\t▪\t", "\t■\t"]
        raw.enumerateAttributes(in: NSRange(location: 0, length: raw.length)) { attrs, range, _ in
            var text = (raw.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }
            // Google's HTML export uses non-breaking spaces (U+00A0) adjacent to
            // styled inline tags. Normalize to regular space so round-trip matches.
            text = text.replacingOccurrences(of: "\u{00A0}", with: " ")

            var traits: NSFontDescriptor.SymbolicTraits = []
            if let font = attrs[.font] as? NSFont {
                let t = font.fontDescriptor.symbolicTraits
                if t.contains(.bold) { traits.insert(.bold) }
                if t.contains(.italic) { traits.insert(.italic) }
            }

            var canonical: [NSAttributedString.Key: Any] = [:]
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
            canonical[.font] = NSFont(descriptor: descriptor, size: 0) ?? baseFont

            let link = allowedLink(attrs[.link])
            if let link { canonical[.link] = link }

            let underlined: Bool = {
                // Any link's underline is link styling, even one we drop.
                if attrs[.link] != nil { return false }
                if let n = attrs[.underlineStyle] as? Int { return n != 0 }
                if let n = attrs[.underlineStyle] as? NSNumber { return n.intValue != 0 }
                return false
            }()
            if underlined { canonical[.underlineStyle] = 1 }

            if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty {
                let lists = style.textLists.enumerated().map { level, list -> NSTextList in
                    guard importedBullets.contains(list.markerFormat) else { return list }
                    if let replacement = bulletLists[ObjectIdentifier(list)] { return replacement }
                    let replacement = NSTextList(markerFormat: level == 0 ? bulletMarkerFormat : .hyphen, options: 0)
                    bulletLists[ObjectIdentifier(list)] = replacement
                    return replacement
                }
                if let last = lists.last, last !== style.textLists.last, importedBulletMarkers.contains(text) {
                    text = "\t\(last.marker(forItemNumber: 1))\t"
                }
                canonical[.paragraphStyle] = listParagraphStyle(lists)
            }

            result.append(NSAttributedString(string: text, attributes: canonical))
        }
        return result
    }
}

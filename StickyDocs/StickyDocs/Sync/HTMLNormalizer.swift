import Foundation
import AppKit

// Canonical HTML <-> NSAttributedString conversion for the supported feature set:
// bold, italic, underline, bulleted list, numbered list, and http/https/mailto
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

        var paragraphs: [(text: NSAttributedString, list: ListKind)] = []
        nsString.enumerateSubstrings(
            in: NSRange(location: 0, length: length),
            options: .byParagraphs
        ) { _, paragraphRange, _, _ in
            let para = attributed.attributedSubstring(from: paragraphRange)
            paragraphs.append((para, Self.listKind(of: para)))
        }

        var html = ""
        var i = 0
        while i < paragraphs.count {
            let kind = paragraphs[i].list
            switch kind {
            case .none:
                html += "<p>" + serializeInline(paragraphs[i].text) + "</p>"
                i += 1
            case .bullet, .number:
                let tag = (kind == .bullet) ? "ul" : "ol"
                html += "<\(tag)>"
                while i < paragraphs.count && paragraphs[i].list == kind {
                    let trimmed = trimLeadingMarker(paragraphs[i].text, kind: kind)
                    html += "<li>" + serializeInline(trimmed) + "</li>"
                    i += 1
                }
                html += "</\(tag)>"
            }
        }
        return html
    }

    private enum ListKind { case none, bullet, number }

    private static func listKind(of paragraph: NSAttributedString) -> ListKind {
        guard let ordered = isOrderedList(paragraph) else { return .none }
        return ordered ? .number : .bullet
    }

    // nil when the paragraph isn't a list item; otherwise whether it's numbered.
    // `orderedKey` (stamped from the raw HTML scan) is authoritative for
    // imported content, whose marker format can't be trusted. Lists made in
    // the editor carry a numeric marker format instead, which also survives
    // NSTextView continuing the list onto a new item when Return is pressed.
    static func isOrderedList(_ paragraph: NSAttributedString) -> Bool? {
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
        var ordered = lists.contains { $0.markerFormat == .decimal }
        paragraph.enumerateAttribute(orderedKey, in: range) { value, _, stop in
            if (value as? Bool) == true { ordered = true; stop.pointee = true }
        }
        return ordered
    }

    // Apple's HTML parser includes the rendered list marker (e.g. "\t•\t" or
    // "\t1.\t") as plain text inside each list-item paragraph. We must strip it
    // before serializing, otherwise the next parse would render the marker
    // again on top of the literal text, doubling it.
    //
    // Google's HTML export uses CSS counters and does not include the marker
    // in the text, but does add leading whitespace for indentation. So the
    // marker char is optional in the regex - the whitespace alone matches.
    private static func trimLeadingMarker(_ paragraph: NSAttributedString, kind: ListKind) -> NSAttributedString {
        let pattern: String
        switch kind {
        case .bullet:
            pattern = #"^\s*([•⦁·▪◦◯●○■□*-]\s*)?"#
        case .number:
            pattern = #"^\s*(\d+[.)]?\s*)?"#
        case .none:
            return paragraph
        }
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
    // room so two-digit numbers fit. Display only: indents and tabs never
    // reach the canonical HTML.
    static func listParagraphStyle(_ lists: [NSTextList]) -> NSParagraphStyle {
        let bulletFormats: Set<NSTextList.MarkerFormat> = [bulletMarkerFormat, .disc, .circle, .square, .hyphen]
        let numbered = lists.contains { !bulletFormats.contains($0.markerFormat) }
        let textStart: CGFloat = numbered ? 22 : 16
        let style = NSMutableParagraphStyle()
        style.textLists = lists
        style.tabStops = [NSTextTab(textAlignment: .natural, location: 4),
                          NSTextTab(textAlignment: .natural, location: textStart)]
        style.defaultTabInterval = textStart
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
    // with this custom attribute after canonicalization.
    static let orderedKey = NSAttributedString.Key("com.balenet.StickyDocs.ordered")

    private static func scanListItemOrderedFlags(_ html: String) -> [Bool] {
        var stack: [Bool] = []
        var flags: [Bool] = []
        guard let regex = try? NSRegularExpression(pattern: #"<(/?)(ol|ul|li)[^>]*>"#, options: [.caseInsensitive]) else {
            return flags
        }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let isClose = ns.substring(with: match.range(at: 1)) == "/"
            let tag = ns.substring(with: match.range(at: 2)).lowercased()
            switch (tag, isClose) {
            case ("ol", false): stack.append(true)
            case ("ul", false): stack.append(false)
            case ("ol", true), ("ul", true): _ = stack.popLast()
            case ("li", false): flags.append(stack.last ?? false)
            default: break
            }
        }
        return flags
    }

    @MainActor
    static func attributedString(from html: String) -> NSAttributedString {
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
        let flags = scanListItemOrderedFlags(html)
        return tagOrderedListItems(canonical, orderedFlags: flags)
    }

    // Walk paragraphs of the canonical attributed string. For each paragraph
    // that is a list item (has textLists set in its paragraphStyle), consume
    // the next ordered flag and stamp the paragraph with `orderedKey` if true.
    private static func tagOrderedListItems(_ attr: NSAttributedString, orderedFlags: [Bool]) -> NSAttributedString {
        guard !orderedFlags.isEmpty else { return attr }
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
            guard flagIdx < orderedFlags.count else { return }
            let ordered = orderedFlags[flagIdx]
            flagIdx += 1
            if ordered {
                mutable.addAttribute(orderedKey, value: true, range: paragraphRange)
            }
        }
        return mutable
    }

    private static func canonicalize(_ raw: NSAttributedString) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()
        // Imported bulleted lists get the editor's bullet glyph. One
        // replacement per source list, so items stay in the same list.
        var bulletLists: [ObjectIdentifier: NSTextList] = [:]
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
                let lists = style.textLists.map { list -> NSTextList in
                    guard list.markerFormat == .disc else { return list }
                    if let replacement = bulletLists[ObjectIdentifier(list)] { return replacement }
                    let replacement = NSTextList(markerFormat: bulletMarkerFormat, options: 0)
                    bulletLists[ObjectIdentifier(list)] = replacement
                    return replacement
                }
                if lists.first?.markerFormat == bulletMarkerFormat, text == "\t•\t" {
                    text = "\t\(bulletMarkerFormat.rawValue)\t"
                }
                canonical[.paragraphStyle] = listParagraphStyle(lists)
            }

            result.append(NSAttributedString(string: text, attributes: canonical))
        }
        return result
    }
}

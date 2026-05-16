import Foundation
import AppKit

// Canonical HTML <-> NSAttributedString conversion for the supported v1 feature set:
// bold, italic, underline, bulleted list, numbered list.
//
// The serializer emits a minimal, deterministic HTML subset.
// The parser accepts arbitrary HTML (including Drive's verbose export),
// canonicalizes the resulting NSAttributedString to only carry the
// attributes we care about, and discards everything else (font family,
// size, color, alignment, indent, links, etc).
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
        guard paragraph.length > 0,
              let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
              let innermost = style.textLists.last
        else { return .none }
        let format = innermost.markerFormat.rawValue.lowercased()
        if format.contains("decimal") || format.contains("1") {
            return .number
        }
        return .bullet
    }

    // Apple's HTML parser includes the rendered list marker (e.g. "\t•\t" or
    // "\t1.\t") as plain text inside each list-item paragraph. We must strip it
    // before serializing, otherwise the next parse would render the marker
    // again on top of the literal text, doubling it.
    private static func trimLeadingMarker(_ paragraph: NSAttributedString, kind: ListKind) -> NSAttributedString {
        let pattern: String
        switch kind {
        case .bullet:
            pattern = #"^\s*[•·▪◦◯●○■□*-]\s*"#
        case .number:
            pattern = #"^\s*\d+[.)]?\s*"#
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
            let underline: Bool = {
                if let n = attrs[.underlineStyle] as? Int { return n != 0 }
                if let n = attrs[.underlineStyle] as? NSNumber { return n.intValue != 0 }
                return false
            }()

            var open = ""
            var close = ""
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

    // MARK: - HTML -> canonical NSAttributedString

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
        return canonicalize(raw)
    }

    private static func canonicalize(_ raw: NSAttributedString) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let result = NSMutableAttributedString()
        raw.enumerateAttributes(in: NSRange(location: 0, length: raw.length)) { attrs, range, _ in
            let text = (raw.string as NSString).substring(with: range)
            guard !text.isEmpty else { return }

            var traits: NSFontDescriptor.SymbolicTraits = []
            if let font = attrs[.font] as? NSFont {
                let t = font.fontDescriptor.symbolicTraits
                if t.contains(.bold) { traits.insert(.bold) }
                if t.contains(.italic) { traits.insert(.italic) }
            }

            var canonical: [NSAttributedString.Key: Any] = [:]
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
            canonical[.font] = NSFont(descriptor: descriptor, size: 0) ?? baseFont

            let underlined: Bool = {
                if let n = attrs[.underlineStyle] as? Int { return n != 0 }
                if let n = attrs[.underlineStyle] as? NSNumber { return n.intValue != 0 }
                return false
            }()
            if underlined { canonical[.underlineStyle] = 1 }

            if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty {
                let pstyle = NSMutableParagraphStyle()
                pstyle.textLists = style.textLists
                canonical[.paragraphStyle] = pstyle
            }

            result.append(NSAttributedString(string: text, attributes: canonical))
        }
        return result
    }
}

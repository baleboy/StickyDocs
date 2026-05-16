import Foundation
import AppKit

// Pushes an NSAttributedString into a Google Doc body using a single atomic
// Docs API `batchUpdate` (delete-all + insertText + updateTextStyle + bullets).
struct GoogleDocsClient {
    let accessToken: () async throws -> String

    func replaceDocumentBody(docId: String, with attributed: NSAttributedString) async throws {
        let endIndex = try await fetchBodyEndIndex(docId: docId)
        let encoded = await DocsBatchEncoder.encode(attributed, currentBodyEndIndex: endIndex)
        guard !encoded.requests.isEmpty else { return }
        try await batchUpdate(docId: docId, requests: encoded.requests)
    }

    // MARK: - HTTP

    private func fetchBodyEndIndex(docId: String) async throws -> Int {
        let token = try await accessToken()
        var comps = URLComponents(string: "https://docs.googleapis.com/v1/documents/\(docId)")!
        comps.queryItems = [.init(name: "fields", value: "body(content(endIndex))")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct DocShape: Decodable {
            struct Body: Decodable {
                struct Element: Decodable { let endIndex: Int? }
                let content: [Element]
            }
            let body: Body
        }
        let doc = try JSONDecoder().decode(DocShape.self, from: data)
        return doc.body.content.compactMap { $0.endIndex }.max() ?? 1
    }

    private func batchUpdate(docId: String, requests: [DocsRequest]) async throws {
        let token = try await accessToken()
        var req = URLRequest(url: URL(string: "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(BatchUpdateBody(requests: requests))
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let reqStr = String(data: body, encoding: .utf8) ?? ""
            let respStr = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GoogleDocs", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "\(respStr)\nREQUEST: \(reqStr)"])
        }
    }

    private static func assertOK(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "GoogleDocs",
                          code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: body])
        }
    }
}

// MARK: - Request types (Docs API JSON shapes)

private struct BatchUpdateBody: Encodable {
    let requests: [DocsRequest]
}

enum DocsRequest: Encodable {
    case deleteContentRange(DocsRange)
    case insertText(location: Int, text: String)
    case updateTextStyle(DocsRange, bold: Bool?, italic: Bool?, underline: Bool?)
    case createParagraphBullets(DocsRange, ordered: Bool)
    case deleteParagraphBullets(DocsRange)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .deleteContentRange(let r):
            try container.encode(DeleteContentRange(range: r), forKey: .deleteContentRange)
        case .insertText(let loc, let text):
            try container.encode(InsertText(location: .init(index: loc), text: text), forKey: .insertText)
        case .updateTextStyle(let r, let bold, let italic, let underline):
            try container.encode(UpdateTextStyle(range: r, bold: bold, italic: italic, underline: underline),
                                 forKey: .updateTextStyle)
        case .createParagraphBullets(let r, let ordered):
            try container.encode(CreateParagraphBullets(
                range: r,
                bulletPreset: ordered ? "NUMBERED_DECIMAL_ALPHA_ROMAN" : "BULLET_DISC_CIRCLE_SQUARE"
            ), forKey: .createParagraphBullets)
        case .deleteParagraphBullets(let r):
            try container.encode(DeleteParagraphBullets(range: r), forKey: .deleteParagraphBullets)
        }
    }

    enum CodingKeys: String, CodingKey {
        case deleteContentRange, insertText, updateTextStyle, createParagraphBullets, deleteParagraphBullets
    }
}

struct DocsRange: Encodable {
    let startIndex: Int
    let endIndex: Int
}

private struct DeleteContentRange: Encodable { let range: DocsRange }
private struct InsertText: Encodable {
    struct Location: Encodable { let index: Int }
    let location: Location
    let text: String
}
private struct UpdateTextStyle: Encodable {
    let range: DocsRange
    let bold: Bool?
    let italic: Bool?
    let underline: Bool?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(range, forKey: .range)
        var ts = c.nestedContainer(keyedBy: StyleKeys.self, forKey: .textStyle)
        var fields: [String] = []
        if let b = bold { try ts.encode(b, forKey: .bold); fields.append("bold") }
        if let i = italic { try ts.encode(i, forKey: .italic); fields.append("italic") }
        if let u = underline { try ts.encode(u, forKey: .underline); fields.append("underline") }
        try c.encode(fields.joined(separator: ","), forKey: .fields)
    }

    enum CodingKeys: String, CodingKey { case range, textStyle, fields }
    enum StyleKeys: String, CodingKey { case bold, italic, underline }
}
private struct CreateParagraphBullets: Encodable {
    let range: DocsRange
    let bulletPreset: String
}
private struct DeleteParagraphBullets: Encodable {
    let range: DocsRange
}

// MARK: - NSAttributedString -> Docs batchUpdate operations

enum DocsBatchEncoder {

    struct Result {
        let requests: [DocsRequest]
    }

    @MainActor
    static func encode(_ attributed: NSAttributedString, currentBodyEndIndex: Int) -> Result {
        var requests: [DocsRequest] = []

        // Delete existing content (everything except the implicit final newline).
        // A fresh Doc has endIndex == 2 (just "\n") — nothing to delete.
        if currentBodyEndIndex > 2 {
            requests.append(.deleteContentRange(DocsRange(startIndex: 1, endIndex: currentBodyEndIndex - 1)))
        }

        let walk = Self.walk(attributed)
        // Drop the trailing newline; the Doc's required trailing "\n" serves
        // as the last paragraph terminator. Otherwise we'd add an extra
        // empty paragraph on every push.
        var insertText = walk.plainText
        if insertText.hasSuffix("\n") { insertText.removeLast() }
        if !insertText.isEmpty {
            requests.append(.insertText(location: 1, text: insertText))
            // Reset all inline styles on the inserted range. Without this, the
            // inserted text inherits whatever bold/italic/underline state was
            // active at the insertion point (which can persist from a prior
            // batchUpdate's deleted content).
            let insertLen = (insertText as NSString).length
            requests.append(.updateTextStyle(
                DocsRange(startIndex: 1, endIndex: 1 + insertLen),
                bold: false, italic: false, underline: false
            ))
            // Reset paragraph-level bullets on the entire body. Bullet state is
            // a paragraph property; deleteContentRange doesn't clear it from the
            // surviving trailing newline, and new paragraphs inherit it from
            // the insertion point. Range includes the doc's trailing newline.
            requests.append(.deleteParagraphBullets(
                DocsRange(startIndex: 1, endIndex: 1 + insertLen + 1)
            ))
        }
        for run in walk.styleRuns {
            requests.append(.updateTextStyle(
                DocsRange(startIndex: run.start, endIndex: run.end),
                bold: run.bold ? true : nil,
                italic: run.italic ? true : nil,
                underline: run.underline ? true : nil
            ))
        }
        for bullet in walk.bulletRanges {
            requests.append(.createParagraphBullets(
                DocsRange(startIndex: bullet.start, endIndex: bullet.end),
                ordered: bullet.ordered
            ))
        }
        return Result(requests: requests)
    }

    private struct StyleRun { let start: Int; let end: Int; let bold: Bool; let italic: Bool; let underline: Bool }
    private struct BulletRange { let start: Int; let end: Int; let ordered: Bool }
    private struct Walk { let plainText: String; let styleRuns: [StyleRun]; let bulletRanges: [BulletRange] }

    @MainActor
    private static func walk(_ attributed: NSAttributedString) -> Walk {
        var plainText = ""
        var styleRuns: [StyleRun] = []
        var bulletRanges: [BulletRange] = []
        var docsIdx = 1

        var pendingBulletStart: Int?
        var pendingBulletOrdered: Bool?

        let ns = attributed.string as NSString
        let totalRange = NSRange(location: 0, length: ns.length)

        ns.enumerateSubstrings(in: totalRange, options: .byParagraphs) { _, paragraphRange, _, _ in
            let paragraph = attributed.attributedSubstring(from: paragraphRange)
            let kind = paragraphListKind(paragraph)
            let body = (kind == .none) ? paragraph : trimLeadingMarker(paragraph, kind: kind)

            let paragraphStartDocsIdx = docsIdx

            // Walk inline attribute runs within this paragraph.
            let bodyNS = body.string as NSString
            body.enumerateAttributes(in: NSRange(location: 0, length: bodyNS.length)) { attrs, range, _ in
                let runText = bodyNS.substring(with: range).replacingOccurrences(of: "\n", with: "")
                guard !runText.isEmpty else { return }
                let runStart = docsIdx
                let runLength = (runText as NSString).length
                let runEnd = runStart + runLength

                plainText += runText
                docsIdx = runEnd

                let (bold, italic, underline) = extractStyles(attrs)
                if bold || italic || underline {
                    styleRuns.append(StyleRun(start: runStart, end: runEnd,
                                              bold: bold, italic: italic, underline: underline))
                }
            }

            // Append paragraph separator.
            plainText += "\n"
            docsIdx += 1
            let paragraphEndDocsIdx = docsIdx

            // Bullet tracking.
            let isOrdered = (kind == .number)
            let isList = (kind != .none)
            if isList {
                if pendingBulletStart == nil || pendingBulletOrdered != isOrdered {
                    if let s = pendingBulletStart, let o = pendingBulletOrdered {
                        bulletRanges.append(BulletRange(start: s, end: paragraphStartDocsIdx, ordered: o))
                    }
                    pendingBulletStart = paragraphStartDocsIdx
                    pendingBulletOrdered = isOrdered
                }
            } else {
                if let s = pendingBulletStart, let o = pendingBulletOrdered {
                    bulletRanges.append(BulletRange(start: s, end: paragraphStartDocsIdx, ordered: o))
                    pendingBulletStart = nil
                    pendingBulletOrdered = nil
                }
            }
            _ = paragraphEndDocsIdx
        }
        if let s = pendingBulletStart, let o = pendingBulletOrdered {
            bulletRanges.append(BulletRange(start: s, end: docsIdx, ordered: o))
        }

        return Walk(plainText: plainText, styleRuns: styleRuns, bulletRanges: bulletRanges)
    }

    private enum ParagraphListKind { case none, bullet, number }

    private static func paragraphListKind(_ paragraph: NSAttributedString) -> ParagraphListKind {
        guard paragraph.length > 0 else { return .none }
        var hasList = false
        paragraph.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: paragraph.length)) { value, _, stop in
            if let style = value as? NSParagraphStyle, !style.textLists.isEmpty {
                hasList = true
                stop.pointee = true
            }
        }
        guard hasList else { return .none }
        var ordered = false
        paragraph.enumerateAttribute(HTMLNormalizer.orderedKey, in: NSRange(location: 0, length: paragraph.length)) { value, _, stop in
            if (value as? Bool) == true { ordered = true; stop.pointee = true }
        }
        return ordered ? .number : .bullet
    }

    private static func trimLeadingMarker(_ paragraph: NSAttributedString, kind: ParagraphListKind) -> NSAttributedString {
        let pattern: String
        switch kind {
        case .bullet: pattern = #"^\s*[•·▪◦◯●○■□*-]\s*"#
        case .number: pattern = #"^\s*\d+[.)]?\s*"#
        case .none: return paragraph
        }
        let ns = paragraph.string as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: paragraph.string, range: NSRange(location: 0, length: ns.length)),
              match.range.location == 0
        else { return paragraph }
        let start = match.range.upperBound
        if start >= paragraph.length { return NSAttributedString(string: "") }
        return paragraph.attributedSubstring(from: NSRange(location: start, length: paragraph.length - start))
    }

    private static func extractStyles(_ attrs: [NSAttributedString.Key: Any]) -> (bold: Bool, italic: Bool, underline: Bool) {
        var bold = false, italic = false, underline = false
        if let font = attrs[.font] as? NSFont {
            let t = font.fontDescriptor.symbolicTraits
            bold = t.contains(.bold)
            italic = t.contains(.italic)
        }
        if let n = attrs[.underlineStyle] as? Int { underline = (n != 0) }
        else if let n = attrs[.underlineStyle] as? NSNumber { underline = (n.intValue != 0) }
        return (bold, italic, underline)
    }
}

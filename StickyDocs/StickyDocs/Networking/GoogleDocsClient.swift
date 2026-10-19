import Foundation
import AppKit

// Pushes an NSAttributedString into a Google Doc body using a single atomic
// Docs API `batchUpdate` (delete-all + insertText + updateTextStyle + bullets).
struct GoogleDocsClient {
    let accessToken: () async throws -> String

    func fetchRevisionId(docId: String) async throws -> String {
        let token = try await accessToken()
        var comps = URLComponents(string: "https://docs.googleapis.com/v1/documents/\(docId)")!
        comps.queryItems = [.init(name: "fields", value: "revisionId")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct Resp: Decodable { let revisionId: String }
        return try JSONDecoder().decode(Resp.self, from: data).revisionId
    }

    // Replaces the whole body and returns the Doc's revisionId after the write.
    //
    // If `expectedRevisionId` is given and the Doc has moved past it, throws
    // RemoteRevisionChangedError without writing. The batchUpdate is also
    // pinned (writeControl.requiredRevisionId) to the revision the delete
    // range was computed from, so a remote edit landing between our GET and
    // the write is rejected instead of silently erased. The returned id comes
    // from the batchUpdate response, so it is exactly the revision we wrote —
    // never a later remote edit we'd then mistake for our own.
    @discardableResult
    func replaceDocumentBody(
        docId: String,
        with attributed: NSAttributedString,
        expectedRevisionId: String? = nil
    ) async throws -> String {
        let snapshot = try await fetchBodySnapshot(docId: docId)
        if let expectedRevisionId, snapshot.revisionId != expectedRevisionId {
            throw RemoteRevisionChangedError()
        }
        let encoded = await DocsBatchEncoder.encode(attributed, currentBodyEndIndex: snapshot.endIndex)
        guard !encoded.requests.isEmpty else { return snapshot.revisionId }
        let newRevisionId = try await batchUpdate(
            docId: docId,
            requests: encoded.requests,
            requiredRevisionId: snapshot.revisionId
        )
        if let newRevisionId { return newRevisionId }
        return try await fetchRevisionId(docId: docId)
    }

    // MARK: - HTTP

    private func fetchBodySnapshot(docId: String) async throws -> (revisionId: String, endIndex: Int) {
        let token = try await accessToken()
        var comps = URLComponents(string: "https://docs.googleapis.com/v1/documents/\(docId)")!
        comps.queryItems = [.init(name: "fields", value: "revisionId,body(content(endIndex))")]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.assertOK(response: response, data: data)
        struct DocShape: Decodable {
            struct Body: Decodable {
                struct Element: Decodable { let endIndex: Int? }
                let content: [Element]
            }
            let revisionId: String
            let body: Body
        }
        let doc = try JSONDecoder().decode(DocShape.self, from: data)
        return (doc.revisionId, doc.body.content.compactMap { $0.endIndex }.max() ?? 1)
    }

    // Returns the post-write revisionId from the response's writeControl.
    private func batchUpdate(docId: String, requests: [DocsRequest], requiredRevisionId: String) async throws -> String? {
        let token = try await accessToken()
        var req = URLRequest(url: URL(string: "https://docs.googleapis.com/v1/documents/\(docId):batchUpdate")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(BatchUpdateBody(
            requests: requests,
            writeControl: .init(requiredRevisionId: requiredRevisionId)
        ))
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let reqStr = String(data: body, encoding: .utf8) ?? ""
            let respStr = String(data: data, encoding: .utf8) ?? ""
            // A stale requiredRevisionId is reported as a 400 whose message
            // names the revision; other 400s (bad ranges etc.) don't.
            if http.statusCode == 400, respStr.range(of: "revision", options: .caseInsensitive) != nil {
                throw RemoteRevisionChangedError()
            }
            throw NSError(domain: "GoogleDocs", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "\(respStr)\nREQUEST: \(reqStr)"])
        }
        struct Resp: Decodable {
            struct WriteControl: Decodable { let requiredRevisionId: String? }
            let writeControl: WriteControl?
        }
        return (try? JSONDecoder().decode(Resp.self, from: data))?.writeControl?.requiredRevisionId
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
    struct WriteControl: Encodable { let requiredRevisionId: String }
    let requests: [DocsRequest]
    let writeControl: WriteControl
}

enum DocsRequest: Encodable {
    case deleteContentRange(DocsRange)
    case insertText(location: Int, text: String)
    // `link` is written with Docs' own link styling (underline + link
    // color), as the Docs editor does. `resetLink` instead clears any link
    // and text color on the range.
    case updateTextStyle(DocsRange, bold: Bool?, italic: Bool?, underline: Bool?, link: URL? = nil, resetLink: Bool = false)
    case createParagraphBullets(DocsRange, ordered: Bool)
    case deleteParagraphBullets(DocsRange)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .deleteContentRange(let r):
            try container.encode(DeleteContentRange(range: r), forKey: .deleteContentRange)
        case .insertText(let loc, let text):
            try container.encode(InsertText(location: .init(index: loc), text: text), forKey: .insertText)
        case .updateTextStyle(let r, let bold, let italic, let underline, let link, let resetLink):
            try container.encode(UpdateTextStyle(range: r, bold: bold, italic: italic, underline: underline,
                                                 link: link, resetLink: resetLink),
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
    let link: URL?
    let resetLink: Bool

    // Docs' default link color, #1155cc.
    static let linkColor = RGBColor(red: 17.0 / 255, green: 85.0 / 255, blue: 204.0 / 255)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(range, forKey: .range)
        var ts = c.nestedContainer(keyedBy: StyleKeys.self, forKey: .textStyle)
        var fields: [String] = []
        if let b = bold { try ts.encode(b, forKey: .bold); fields.append("bold") }
        if let i = italic { try ts.encode(i, forKey: .italic); fields.append("italic") }
        if let link {
            try ts.encode(true, forKey: .underline)
            try ts.encode(Link(url: link.absoluteString), forKey: .link)
            try ts.encode(OptionalColor(color: .init(rgbColor: Self.linkColor)), forKey: .foregroundColor)
            fields += ["underline", "link", "foregroundColor"]
        } else if let u = underline {
            try ts.encode(u, forKey: .underline); fields.append("underline")
        }
        // A field named in `fields` but absent from `textStyle` is cleared.
        if resetLink && link == nil { fields += ["link", "foregroundColor"] }
        try c.encode(fields.joined(separator: ","), forKey: .fields)
    }

    struct Link: Encodable { let url: String }
    struct RGBColor: Encodable { let red: Double; let green: Double; let blue: Double }
    struct OptionalColor: Encodable {
        struct Color: Encodable { let rgbColor: RGBColor }
        let color: Color
    }

    enum CodingKeys: String, CodingKey { case range, textStyle, fields }
    enum StyleKeys: String, CodingKey { case bold, italic, underline, link, foregroundColor }
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
            // inserted text inherits whatever bold/italic/underline/link state
            // was active at the insertion point (which can persist from a
            // prior batchUpdate's deleted content).
            let insertLen = (insertText as NSString).length
            requests.append(.updateTextStyle(
                DocsRange(startIndex: 1, endIndex: 1 + insertLen),
                bold: false, italic: false, underline: false, resetLink: true
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
                underline: run.underline ? true : nil,
                link: run.link
            ))
        }
        // Each createParagraphBullets turns its items' leading tabs into
        // nesting levels and deletes them, shifting all text after it. Going
        // from the end of the Doc keeps the ranges still to come valid.
        for bullet in walk.bulletRanges.reversed() {
            requests.append(.createParagraphBullets(
                DocsRange(startIndex: bullet.start, endIndex: bullet.end),
                ordered: bullet.ordered
            ))
        }
        return Result(requests: requests)
    }

    private struct StyleRun { let start: Int; let end: Int; let bold: Bool; let italic: Bool; let underline: Bool; let link: URL? }
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
            let path = HTMLNormalizer.listPath(paragraph)
            let body = path.map { HTMLNormalizer.trimListMarker(paragraph, ordered: $0.last!) } ?? paragraph

            let paragraphStartDocsIdx = docsIdx

            // Docs takes a list item's nesting level from its leading tabs.
            if let path, path.count > 1 {
                plainText += String(repeating: "\t", count: path.count - 1)
                docsIdx += path.count - 1
            }

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

                let (bold, italic, underline, link) = extractStyles(attrs)
                if bold || italic || underline || link != nil {
                    styleRuns.append(StyleRun(start: runStart, end: runEnd,
                                              bold: bold, italic: italic, underline: underline, link: link))
                }
            }

            // Append paragraph separator.
            plainText += "\n"
            docsIdx += 1
            let paragraphEndDocsIdx = docsIdx

            // Bullet tracking. A Doc list has one preset for all its levels,
            // so the outermost list's kind decides it.
            let isOrdered = path?.first == true
            if path != nil {
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

    private static func extractStyles(_ attrs: [NSAttributedString.Key: Any]) -> (bold: Bool, italic: Bool, underline: Bool, link: URL?) {
        var bold = false, italic = false, underline = false
        let link = HTMLNormalizer.allowedLink(attrs[.link])
        if let font = attrs[.font] as? NSFont {
            let t = font.fontDescriptor.symbolicTraits
            bold = t.contains(.bold)
            italic = t.contains(.italic)
        }
        if let n = attrs[.underlineStyle] as? Int { underline = (n != 0) }
        else if let n = attrs[.underlineStyle] as? NSNumber { underline = (n.intValue != 0) }
        // Link styling stands in for underline, as in HTMLNormalizer.
        return (bold, italic, link == nil && underline, link)
    }
}

import Foundation
import AppKit

// Drives the end-to-end Doc round-trip test:
//   1. Create a throwaway Google Doc
//   2. For each case: push NSAttributedString via Docs batchUpdate
//   3. Pull the Doc back as HTML via Drive export
//   4. Normalize and compare canonical HTML
//   5. Delete the Doc
struct RoundTripHarness {
    struct CaseResult {
        let name: String
        let passed: Bool
        let expected: String
        let actual: String
        let error: String?
    }

    let accessToken: () async throws -> String
    var drive: GoogleDriveClient { GoogleDriveClient(accessToken: accessToken) }
    var docs: GoogleDocsClient { GoogleDocsClient(accessToken: accessToken) }

    @MainActor
    func run(cases: [(name: String, html: String)]) async throws -> [CaseResult] {
        let title = "StickyDocs Round-Trip Test \(Int(Date().timeIntervalSince1970))"
        let docId = try await drive.createDoc(title: title)
        defer {
            Task { try? await drive.deleteFile(id: docId) }
        }

        var results: [CaseResult] = []
        for (name, sourceHTML) in cases {
            let expectedAttr = HTMLNormalizer.attributedString(from: sourceHTML)
            let expectedCanonical = HTMLNormalizer.html(from: expectedAttr)
            do {
                try await docs.replaceDocumentBody(docId: docId, with: expectedAttr)
                let pulledHTML = try await drive.exportAsHTML(docId: docId)
                let pulledAttr = HTMLNormalizer.attributedString(from: pulledHTML)
                let actualCanonical = HTMLNormalizer.html(from: pulledAttr)
                results.append(CaseResult(
                    name: name,
                    passed: expectedCanonical == actualCanonical,
                    expected: expectedCanonical,
                    actual: actualCanonical,
                    error: nil
                ))
            } catch {
                results.append(CaseResult(
                    name: name,
                    passed: false,
                    expected: expectedCanonical,
                    actual: "",
                    error: error.localizedDescription
                ))
            }
        }
        return results
    }

    static let defaultCases: [(name: String, html: String)] = [
        ("plain", "<p>hello world</p>"),
        ("bold", "<p>hello <b>bold</b> world</p>"),
        ("italic", "<p>some <i>italic</i> text</p>"),
        ("underline", "<p>some <u>underlined</u> text</p>"),
        ("bold-italic", "<p><b><i>both</i></b></p>"),
        ("all-three", "<p><b><i><u>all three</u></i></b></p>"),
        ("multi-paragraph", "<p>first</p><p>second</p>"),
        ("bullets", "<ul><li>one</li><li>two</li><li>three</li></ul>"),
        ("numbered", "<ol><li>first</li><li>second</li></ol>"),
        ("mixed", "<p>intro</p><ul><li>a</li><li>b</li></ul><p>end</p>"),
        ("nested-bullets", "<ul><li>a<ul><li>b<ul><li>c</li></ul></li><li>d</li></ul></li><li>e</li></ul>"),
        ("nested-numbered", "<p>intro</p><ol><li>one<ol><li>sub</li></ol></li><li>two</li></ol><p>end</p>"),
        ("link", "<p>see <a href=\"https://example.com/a?b=1&amp;c=2\">example</a> here</p>"),
        ("link-bold", "<p><a href=\"https://example.com\"><b>bold link</b></a></p>"),
        ("link-in-list", "<ul><li>go <a href=\"https://example.com\">https://example.com</a></li></ul>"),
        ("mailto", "<p><a href=\"mailto:a@example.com\">a@example.com</a></p>"),
        // Whitespace and escaping: any of these failing to round-trip makes a
        // content-neutral revision bump look like a remote edit (false conflict).
        ("empty-line", "<p>first</p><p></p><p>second</p>"),
        ("double-space", "<p>two  spaces</p>"),
        ("trailing-space", "<p>trailing </p>"),
        ("tab", "<p>a\tb</p>"),
        ("escaped", "<p>a &amp; b &lt;c&gt;</p>"),
        ("emoji", "<p>hi 👋 there</p>")
    ]
}

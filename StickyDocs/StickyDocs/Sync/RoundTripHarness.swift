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
        ("mixed", "<p>intro</p><ul><li>a</li><li>b</li></ul><p>end</p>")
    ]
}

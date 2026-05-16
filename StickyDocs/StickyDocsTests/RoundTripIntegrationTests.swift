import Testing
import Foundation
import AppKit
@testable import StickyDocs

// Integration test that hits the real Google Drive + Docs APIs.
//
// Gated by STICKYDOCS_INTEGRATION=1 env var so it doesn't run on every
// `cmd-U`. To enable:
//   1. Run the StickyDocs app, sign in.
//   2. Click "Save creds for tests" - writes refresh token to
//      ~/Library/Application Support/StickyDocs/test_creds.json.
//   3. xcodebuild test -scheme StickyDocs \
//        -only-testing:StickyDocsTests/RoundTripIntegrationTests \
//        STICKYDOCS_INTEGRATION=1
//
// The test refreshes the access token, runs all default round-trip cases,
// and asserts each canonicalizes identically before and after a real Doc
// push + HTML export pull.
@MainActor
struct RoundTripIntegrationTests {

    @Test func allDefaultCasesRoundTrip() async throws {
        // Skip silently when no creds file is present (CI / normal cmd-U).
        guard FileManager.default.fileExists(atPath: TestCredentials.credsPath) else { return }

        let accessToken = try await TestCredentials.refreshAccessToken()
        let harness = RoundTripHarness(accessToken: { accessToken })
        let results = try await harness.run(cases: RoundTripHarness.defaultCases)

        for r in results {
            if let err = r.error {
                #expect(r.passed, "Case '\(r.name)' threw error: \(err)")
            } else {
                #expect(r.passed, "Case '\(r.name)' did not round-trip.\nexpected: \(r.expected)\nactual:   \(r.actual)\(scalarDiff(r.expected, r.actual))")
            }
        }
    }

    private func scalarDiff(_ a: String, _ b: String) -> String {
        let xs = Array(a.unicodeScalars)
        let ys = Array(b.unicodeScalars)
        let common = min(xs.count, ys.count)
        for i in 0..<common where xs[i] != ys[i] {
            return "\nfirst diff at scalar \(i): expected U+\(String(xs[i].value, radix: 16, uppercase: true)) ('\(xs[i])'), actual U+\(String(ys[i].value, radix: 16, uppercase: true)) ('\(ys[i])')"
        }
        if xs.count != ys.count {
            return "\nlength differs: expected \(xs.count), actual \(ys.count)"
        }
        return ""
    }
}

enum TestCredentials {
    enum CredsError: Error, LocalizedError {
        case fileMissing(String)
        case decodeFailed
        case refreshFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileMissing(let path):
                return "test_creds.json not found at \(path). Run the app and click 'Save creds for tests'."
            case .decodeFailed:
                return "test_creds.json is malformed."
            case .refreshFailed(let body):
                return "Token refresh failed: \(body)"
            }
        }
    }

    static let credsPath: String = NSHomeDirectory() + "/Library/Application Support/StickyDocs/test_creds.json"

    static func refreshAccessToken() async throws -> String {
        let url = URL(fileURLWithPath: credsPath)
        guard FileManager.default.fileExists(atPath: credsPath) else {
            throw CredsError.fileMissing(credsPath)
        }
        let data = try Data(contentsOf: url)
        struct Creds: Decodable { let refresh_token: String }
        guard let creds = try? JSONDecoder().decode(Creds.self, from: data) else {
            throw CredsError.decodeFailed
        }

        var body = URLComponents()
        body.queryItems = [
            .init(name: "client_id", value: Secrets.googleClientID),
            .init(name: "client_secret", value: Secrets.googleClientSecret),
            .init(name: "refresh_token", value: creds.refresh_token),
            .init(name: "grant_type", value: "refresh_token")
        ]
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (respData, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CredsError.refreshFailed(String(data: respData, encoding: .utf8) ?? "")
        }
        struct TokenResp: Decodable { let access_token: String }
        return try JSONDecoder().decode(TokenResp.self, from: respData).access_token
    }
}

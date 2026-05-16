import Foundation
import AppKit

@MainActor
final class AuthService {
    enum AuthError: Error, LocalizedError {
        case stateMismatch
        case noAuthCode(String)
        case tokenExchangeFailed(String)
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .stateMismatch: return "OAuth state mismatch"
            case .noAuthCode(let desc): return "No auth code received: \(desc)"
            case .tokenExchangeFailed(let body): return "Token exchange failed: \(body)"
            case .notSignedIn: return "Not signed in"
            }
        }
    }

    static let shared = AuthService()

    private let keychain = KeychainStore(
        service: "com.balenet.StickyDocs.GoogleOAuth",
        account: "default"
    )
    private let scope = "https://www.googleapis.com/auth/drive.file"

    private var cachedTokens: OAuthTokens?

    func currentTokens() throws -> OAuthTokens? {
        if let cachedTokens { return cachedTokens }
        guard let data = try keychain.load() else { return nil }
        let tokens = try JSONDecoder().decode(OAuthTokens.self, from: data)
        cachedTokens = tokens
        return tokens
    }

    func accessToken() async throws -> String {
        guard var tokens = try currentTokens() else { throw AuthError.notSignedIn }
        if tokens.isExpired {
            tokens = try await refresh(using: tokens.refreshToken)
            try persist(tokens)
        }
        return tokens.accessToken
    }

    func signOut() throws {
        cachedTokens = nil
        try keychain.delete()
    }

    func signIn() async throws -> OAuthTokens {
        let server = LoopbackServer()
        let port = try await server.start()
        defer { server.stop() }

        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let expectedState = UUID().uuidString
        let redirectURI = "http://localhost:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: Secrets.googleClientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: expectedState),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent")
        ]
        NSWorkspace.shared.open(comps.url!)

        let params = try await server.waitForRequest()

        if let err = params["error"] {
            throw AuthError.noAuthCode(err)
        }
        guard params["state"] == expectedState else { throw AuthError.stateMismatch }
        guard let code = params["code"] else { throw AuthError.noAuthCode("missing code") }

        let tokens = try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
        try persist(tokens)
        return tokens
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> OAuthTokens {
        var body = URLComponents()
        body.queryItems = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: Secrets.googleClientID),
            .init(name: "client_secret", value: Secrets.googleClientSecret),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier)
        ]
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            scope: decoded.scope ?? scope
        )
    }

    private func refresh(using refreshToken: String) async throws -> OAuthTokens {
        var body = URLComponents()
        body.queryItems = [
            .init(name: "client_id", value: Secrets.googleClientID),
            .init(name: "client_secret", value: Secrets.googleClientSecret),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "grant_type", value: "refresh_token")
        ]
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return OAuthTokens(
            accessToken: decoded.access_token,
            refreshToken: decoded.refresh_token ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            scope: decoded.scope ?? scope
        )
    }

    private func persist(_ tokens: OAuthTokens) throws {
        cachedTokens = tokens
        let data = try JSONEncoder().encode(tokens)
        try keychain.save(data)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let scope: String?
        let token_type: String
    }
}

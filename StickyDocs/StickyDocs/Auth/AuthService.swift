import Foundation
import AppKit
import AuthenticationServices
import Combine

@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var isSignedIn: Bool = false
    enum AuthError: Error, LocalizedError {
        case stateMismatch
        case noAuthCode(String)
        case tokenExchangeFailed(String)
        case notSignedIn
        case malformedClientID
        case sessionStartFailed

        var errorDescription: String? {
            switch self {
            case .stateMismatch: return "OAuth state mismatch"
            case .noAuthCode(let desc): return "No auth code received: \(desc)"
            case .tokenExchangeFailed(let body): return "Token exchange failed: \(body)"
            case .notSignedIn: return "Not signed in"
            case .malformedClientID: return "Secrets.googleClientID is not in the expected *.apps.googleusercontent.com form"
            case .sessionStartFailed: return "Could not start the web authentication session"
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
    private let presentationProvider = WebAuthPresentationProvider()

    private init() {
        refreshSignedInState()
    }

    private func refreshSignedInState() {
        isSignedIn = (try? currentTokens()) != nil
    }

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
            do {
                tokens = try await refresh(using: tokens.refreshToken)
            } catch let error as AuthError {
                // Google rejected the refresh token (revoked, password changed,
                // 6-month inactivity, etc.). The token is dead; clear it so the
                // menu bar flips to "Sign In with Google..." and per-sticky
                // banners surface a re-auth prompt.
                if case .tokenExchangeFailed = error {
                    NSLog("[StickyDocs] refresh rejected, clearing tokens: \(error.localizedDescription)")
                    try? signOut()
                    throw AuthError.notSignedIn
                }
                throw error
            }
            try persist(tokens)
        }
        return tokens.accessToken
    }

    func signOut() throws {
        cachedTokens = nil
        try keychain.delete()
        isSignedIn = false
    }

    func signIn() async throws -> OAuthTokens {
        let callbackScheme = try callbackURLScheme(from: Secrets.googleClientID)
        let redirectURI = "\(callbackScheme):/oauth2redirect"

        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        let expectedState = UUID().uuidString

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
            // select_account forces Google to show the account picker even when
            // the system browser already has a session cookie — otherwise users
            // with multiple Google accounts (work / personal) get silently
            // signed in with whichever one Safari knows about. consent is kept
            // so that re-auth after a revocation reissues a refresh token.
            .init(name: "prompt", value: "select_account consent")
        ]
        let authURL = comps.url!

        let callbackURL = try await runWebAuthSession(url: authURL, scheme: callbackScheme)

        let params = parseQuery(from: callbackURL)
        if let err = params["error"] {
            throw AuthError.noAuthCode(err)
        }
        guard params["state"] == expectedState else { throw AuthError.stateMismatch }
        guard let code = params["code"] else { throw AuthError.noAuthCode("missing code") }

        let tokens = try await exchange(code: code, verifier: verifier, redirectURI: redirectURI)
        try persist(tokens)
        return tokens
    }

    private func runWebAuthSession(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme
            ) { callback, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let callback {
                    cont.resume(returning: callback)
                } else {
                    cont.resume(throwing: AuthError.sessionStartFailed)
                }
            }
            session.presentationContextProvider = presentationProvider
            session.prefersEphemeralWebBrowserSession = false
            if !session.start() {
                cont.resume(throwing: AuthError.sessionStartFailed)
            }
        }
    }

    private func callbackURLScheme(from clientID: String) throws -> String {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { throw AuthError.malformedClientID }
        let prefix = String(clientID.dropLast(suffix.count))
        guard !prefix.isEmpty else { throw AuthError.malformedClientID }
        return "com.googleusercontent.apps.\(prefix)"
    }

    private func parseQuery(from url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        return out
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> OAuthTokens {
        var items: [URLQueryItem] = [
            .init(name: "code", value: code),
            .init(name: "client_id", value: Secrets.googleClientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code_verifier", value: verifier)
        ]
        if !Secrets.googleClientSecret.isEmpty {
            items.append(.init(name: "client_secret", value: Secrets.googleClientSecret))
        }
        var body = URLComponents()
        body.queryItems = items
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

    func refresh(using refreshToken: String) async throws -> OAuthTokens {
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: Secrets.googleClientID),
            .init(name: "refresh_token", value: refreshToken),
            .init(name: "grant_type", value: "refresh_token")
        ]
        if !Secrets.googleClientSecret.isEmpty {
            items.append(.init(name: "client_secret", value: Secrets.googleClientSecret))
        }
        var body = URLComponents()
        body.queryItems = items
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
        isSignedIn = true
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let scope: String?
        let token_type: String
    }
}

private final class WebAuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

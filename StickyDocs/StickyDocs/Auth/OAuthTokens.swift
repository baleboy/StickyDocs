import Foundation

struct OAuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scope: String

    var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-30)
    }
}

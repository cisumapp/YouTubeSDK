import Foundation
import Testing
@testable import YouTubeSDK

struct YouTubeOAuthTests {
    @Test("Authenticate with YouTube (Interactive)")
    func authFlow() {}

    @Test("Refresh token responses may omit refresh_token")
    func refreshTokenResponseUsesStoredRefreshToken() throws {
        let json = #"{"access_token":"access","expires_in":3600,"scope":"scope","token_type":"Bearer"}"#
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        let token = try response.toOAuthToken(fallbackRefreshToken: "refresh")

        #expect(token.accessToken == "access")
        #expect(token.refreshToken == "refresh")
        #expect(token.scope == "scope")
    }
}

//
//  YouTubeOAuthClient.swift
//  YouTubeSDK
//
//  Acts as the Session Manager for the entire SDK.
//  Use this to Save, Load, and Validate cookies, or authenticate via OAuth.
//

import Foundation

public actor YouTubeOAuthClient {

    private let network: NetworkClient
    public static let sharedCookieKey = "youtube_user_cookies"

    private var cachedToken: OAuthToken?

    public init() {
        let cookies = YouTubeSDKConfig.storage?.load(key: Self.sharedCookieKey)
        let context = InnerTubeContext(client: ClientConfig.ios, cookies: cookies)
        self.network = NetworkClient(context: context)
        self.cachedToken = OAuthTokenStorage.load()
    }

    // MARK: - OAuth Device Code Auth

    /// Starts the OAuth Device Authorization Grant flow.
    /// This returns the device code response — the caller should use it to display
    /// the user code and initiate polling via `pollForToken()`.
    public func startDeviceAuth() async throws -> DeviceCodeResponse {
        let flow = YouTubeOAuthDeviceFlow()
        return try await flow.startAuth()
    }

    /// Polls the token endpoint until the user completes authorization.
    public func pollForToken(deviceCode: String, interval: Int, expiresAt: Date) async throws -> OAuthToken {
        let flow = YouTubeOAuthDeviceFlow()
        let token = try await flow.pollForToken(deviceCode: deviceCode, interval: interval, expiresAt: expiresAt)
        cachedToken = token
        OAuthTokenStorage.save(token)
        return token
    }

    /// Full device auth: starts flow and polls. Convenience method.
    public func authenticateWithDeviceCode() async throws -> OAuthToken {
        let flow = YouTubeOAuthDeviceFlow()
        let response = try await flow.startAuth()
        let token = try await flow.pollForToken(
            deviceCode: response.deviceCode,
            interval: response.interval,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
        cachedToken = token
        OAuthTokenStorage.save(token)
        return token
    }

    /// Returns a valid access token, refreshing if necessary.
    public func getAccessToken() async -> String? {
        if let token = cachedToken, !token.isExpired {
            return token.accessToken
        }

        if let stored = OAuthTokenStorage.load() {
            if stored.isExpired {
                do {
                    let flow = YouTubeOAuthDeviceFlow()
                    let newToken = try await flow.refreshToken(refreshToken: stored.refreshToken)
                    cachedToken = newToken
                    OAuthTokenStorage.save(newToken)
                    return newToken.accessToken
                } catch {
                    print("[YouTubeSDK] Token refresh failed: \(error.localizedDescription)")
                    return nil
                }
            } else {
                cachedToken = stored
                return stored.accessToken
            }
        }

        return nil
    }

    /// Checks if the user has a stored, valid OAuth token.
    public func hasValidToken() async -> Bool {
        await getAccessToken() != nil
    }

    // MARK: - Token Management

    /// Stores an OAuth token manually (for testing or custom flows).
    public func setToken(_ token: OAuthToken) {
        cachedToken = token
        OAuthTokenStorage.save(token)
    }

    /// Clears the cached and stored OAuth token.
    public func clearToken() {
        cachedToken = nil
        OAuthTokenStorage.delete()
    }

    /// Returns the currently cached token (without refresh).
    public func currentToken() -> OAuthToken? {
        cachedToken
    }

    // MARK: - Token Refresh

    /// Forces a token refresh using the stored refresh token.
    public func refreshToken() async throws -> OAuthToken {
        guard let stored = OAuthTokenStorage.load() else {
            throw OAuthError.unknownError("No refresh token available")
        }

        let flow = YouTubeOAuthDeviceFlow()
        let newToken = try await flow.refreshToken(refreshToken: stored.refreshToken)
        cachedToken = newToken
        OAuthTokenStorage.save(newToken)
        return newToken
    }

    // MARK: - Cookie Auth (Existing)

    /// Verifies if the currently stored cookies are valid by hitting a private endpoint.
    public func validateSession() async -> Bool {
        do {
            let data = try await network.get("account/account_menu")

            if let json = String(data: data, encoding: .utf8),
               json.contains("googleAccountHeaderRenderer") {
                return true
            }
        } catch {
            print("[YouTubeSDK] Cookie auth validation failed: \(error)")
        }
        return false
    }

    // MARK: - Static Helpers

    /// Saves the cookies string (from GoogleLoginView) to the secure Keychain.
    public static func saveCookies(_ cookies: String) {
        YouTubeSDKConfig.storage?.save(cookies, key: sharedCookieKey)
    }

    /// Loads the saved cookies string to pass into other Clients.
    public static func loadCookies() -> String? {
        YouTubeSDKConfig.storage?.load(key: sharedCookieKey)
    }

    /// Wipes the session (Logout).
    public static func logout() {
        YouTubeSDKConfig.storage?.delete(key: sharedCookieKey)
        OAuthTokenStorage.delete()
    }

    /// Wipes OAuth tokens only (preserves cookies).
    public static func logoutOAuth() {
        OAuthTokenStorage.delete()
    }
}

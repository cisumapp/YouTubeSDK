//
//  YouTube.swift
//  YouTubeSDK
//
//  The central entry point for the YouTubeSDK.
//  Use this manager to access Main YouTube, Music, Charts, and Auth functionalities.
//

import Foundation

@MainActor
public final class YouTube {

    public static let shared = YouTube()

    /// Cookie-based session cookies. Setting this updates all child clients.
    public var cookies: String? {
        didSet {
            updateClients()
        }
    }

    /// OAuth Bearer access token. Set automatically after device auth.
    /// Used for authenticated InnerTube requests.
    public private(set) var accessToken: String?

    private var oauthToken: OAuthToken?

    /// Main YouTube Client (Videos, Search, Browsing)
    public private(set) var main: YouTubeClient

    /// YouTube Music Client (Discovery, Artist/Album/Playlist, Library)
    public private(set) var music: YouTubeMusicClient

    /// YouTube Charts Client (Top Songs, Videos, Artists)
    public private(set) var charts: YouTubeChartsClient

    /// OAuth and Session Management Client
    public private(set) var oauth: YouTubeOAuthClient

    // DECIPHER ENGINE: WebViewPoTokenProvider commented out — not needed when streams have direct URLs.
    // Re-enable if YouTube re-introduces PO token requirements.
    // private let poTokenProvider = WebViewPoTokenProvider()
    private let poTokenProvider: PoTokenProvider? = nil

    public init(cookies: String? = nil) {
        self.cookies = cookies ?? YouTubeOAuthClient.loadCookies()
        self.main = YouTubeClient(cookies: self.cookies, accessToken: nil, poTokenProvider: poTokenProvider)
        self.music = YouTubeMusicClient(cookies: self.cookies, accessToken: nil)
        self.charts = YouTubeChartsClient()
        self.oauth = YouTubeOAuthClient()

        Task {
            await loadStoredToken()
        }
    }

    // MARK: - OAuth Authentication

    /// Authenticates the user via the OAuth Device Authorization Grant flow.
    /// Shows the user their code and polls until authorization completes.
    /// - Returns: The obtained OAuth token.
    public func authenticateWithDeviceCode() async throws -> OAuthToken {
        let token = try await oauth.authenticateWithDeviceCode()
        self.oauthToken = token
        self.accessToken = token.accessToken
        updateClients()
        print("[YouTubeSDK] OAuth authenticated — token expires: \(token.expiresAt)")
        return token
    }

    /// Ensures a valid access token is available, refreshing if needed.
    /// - Returns: A valid access token, or nil if not authenticated.
    public func ensureAccessToken() async -> String? {
        if let token = await oauth.getAccessToken() {
            self.accessToken = token
            updateClients()
            return token
        }
        return nil
    }

    /// Checks if the user is authenticated via OAuth.
    public var isOAuthAuthenticated: Bool {
        oauthToken != nil
    }

    /// Checks if the user is authenticated via cookies.
    public var isCookieAuthenticated: Bool {
        cookies != nil
    }

    /// Checks if the user is authenticated via either method.
    public var isAuthenticated: Bool {
        isOAuthAuthenticated || isCookieAuthenticated
    }

    // MARK: - Sign Out

    /// Signs out from both OAuth and cookie-based authentication.
    public func signOut() {
        cookies = nil
        accessToken = nil
        oauthToken = nil
        Task {
            await oauth.clearToken()
        }
        YouTubeOAuthClient.logout()
        updateClients()
        print("[YouTubeSDK] Signed out")
    }

    /// Signs out from OAuth only (preserves cookie session).
    public func signOutOAuth() {
        accessToken = nil
        oauthToken = nil
        Task {
            await oauth.clearToken()
        }
        YouTubeOAuthClient.logoutOAuth()
        updateClients()
        print("[YouTubeSDK] OAuth session cleared")
    }

    // MARK: - Private

    private func loadStoredToken() async {
        if let token = OAuthTokenStorage.load() {
            self.oauthToken = token
            if !token.isExpired {
                self.accessToken = token.accessToken
            } else {
                do {
                    let refreshed = try await oauth.refreshToken()
                    self.oauthToken = refreshed
                    self.accessToken = refreshed.accessToken
                    updateClients()
                } catch {
                    print("[YouTubeSDK] Stored token expired and could not be refreshed: \(error)")
                    self.accessToken = nil
                }
            }
        }
    }

    private func updateClients() {
        self.main = YouTubeClient(cookies: cookies, accessToken: accessToken, poTokenProvider: poTokenProvider)
        self.music = YouTubeMusicClient(cookies: cookies, accessToken: accessToken)
    }
}

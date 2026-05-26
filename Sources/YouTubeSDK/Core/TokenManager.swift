import Foundation

// MARK: - TokenManager
//
// Actor that owns all Keychain storage for OAuth tokens.
//
// InternalAuthService creates and holds a TokenManager, reading initial token state
// via `initialSnapshot` (nonisolated — safe from synchronous init).
// Consumers that want to react to future token changes subscribe to `updates`.

public actor TokenManager {

    // MARK: - Types

    public enum Update: Sendable {
        case refreshed(token: String?, expiresAt: Date?)
        case signedOut
    }

    public struct Snapshot: Sendable {
        public let accessToken: String?
        public let refreshToken: String?
        public let tokenExpiry: Date?
        public let accountName: String?
        public let accountAvatarURL: URL?
        /// YouTube.com SAPISID cookie for WEB_CREATOR SAPISIDHASH auth.
        public let sapisid: String?
    }

    // MARK: - State

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var accountName: String?
    private var accountAvatarURL: URL?
    private var sapisid: String?

    // MARK: - Stream

    private var continuation: AsyncStream<Update>.Continuation?

    /// Subscribe to receive future token updates without polling InternalAuthService.
    /// `nonisolated let` — accessible without `await`, safe cross-actor.
    public nonisolated let updates: AsyncStream<Update>

    // MARK: - Initial snapshot

    /// Snapshot of Keychain values at init time.
    /// `nonisolated let` — InternalAuthService.init() reads this without `await`.
    public nonisolated let initialSnapshot: Snapshot

    // MARK: - Init

    public init() {
        var cont: AsyncStream<Update>.Continuation!
        let stream = AsyncStream<Update> { cont = $0 }
        updates = stream
        continuation = cont

        let storage = YouTubeSDKConfig.storage
        let snap = Snapshot(
            accessToken:     storage?.load(key: "st_access_token"),
            refreshToken:    storage?.load(key: "st_refresh_token"),
            tokenExpiry: {
                guard let s = storage?.load(key: "st_token_expiry")
                else { return nil }
                return ISO8601DateFormatter().date(from: s)
            }(),
            accountName:     storage?.load(key: "st_account_name"),
            accountAvatarURL: storage?.load(key: "st_avatar_url")
                                .flatMap(URL.init(string:)),
            sapisid:         storage?.load(key: "st_sapisid")
        )
        initialSnapshot  = snap
        accessToken      = snap.accessToken
        refreshToken     = snap.refreshToken
        tokenExpiry      = snap.tokenExpiry
        accountName      = snap.accountName
        accountAvatarURL = snap.accountAvatarURL
        sapisid          = snap.sapisid
    }

    // MARK: - Reads

    public func currentAccessToken() -> String?  { accessToken }
    public func currentRefreshToken() -> String? { refreshToken }
    public func currentTokenExpiry() -> Date?    { tokenExpiry }
    public func currentAccountName() -> String?  { accountName }
    public func currentAvatarURL() -> URL?       { accountAvatarURL }
    public func isSignedIn() -> Bool             { accessToken != nil }

    // MARK: - Mutations

    public func setToken(
        access: String?,
        refresh: String?,
        expiry: Date?,
        accountName: String?,
        avatarURL: URL?
    ) {
        self.accessToken      = access
        self.refreshToken     = refresh
        self.tokenExpiry      = expiry
        self.accountName      = accountName
        self.accountAvatarURL = avatarURL
        persistToStorage()
        continuation?.yield(.refreshed(token: access, expiresAt: expiry))
    }

    /// Persists the SAPISID cookie to storage so it survives app restarts.
    public func setSAPISID(_ value: String?) {
        sapisid = value
        if let value {
            YouTubeSDKConfig.storage?.save(value, key: "st_sapisid")
        } else {
            YouTubeSDKConfig.storage?.delete(key: "st_sapisid")
        }
    }

    public func clearToken() {
        accessToken      = nil
        refreshToken     = nil
        tokenExpiry      = nil
        accountName      = nil
        accountAvatarURL = nil
        sapisid          = nil
        deleteFromStorage()
        continuation?.yield(.signedOut)
    }

    // MARK: - Private Storage I/O

    private func persistToStorage() {
        guard let storage = YouTubeSDKConfig.storage else { return }
        let fmt = ISO8601DateFormatter()
        
        if let accessToken { storage.save(accessToken, key: "st_access_token") } else { storage.delete(key: "st_access_token") }
        if let refreshToken { storage.save(refreshToken, key: "st_refresh_token") } else { storage.delete(key: "st_refresh_token") }
        if let tokenExpiry { storage.save(fmt.string(from: tokenExpiry), key: "st_token_expiry") } else { storage.delete(key: "st_token_expiry") }
        if let accountName { storage.save(accountName, key: "st_account_name") } else { storage.delete(key: "st_account_name") }
        if let accountAvatarURL { storage.save(accountAvatarURL.absoluteString, key: "st_avatar_url") } else { storage.delete(key: "st_avatar_url") }
    }

    private func deleteFromStorage() {
        guard let storage = YouTubeSDKConfig.storage else { return }
        for key in ["st_access_token", "st_refresh_token", "st_token_expiry",
                    "st_account_name", "st_avatar_url", "st_sapisid"] {
            storage.delete(key: key)
        }
    }
}

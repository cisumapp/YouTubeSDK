//
//  OAuthToken.swift
//  YouTubeSDK
//
//  Handles OAuth token storage and retrieval from Keychain.
//

import Foundation

/// Represents an OAuth 2.0 token returned by Google's token endpoint.
public struct OAuthToken: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let scope: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var isExpired: Bool {
        Date() >= expiresAt
    }

    public var isNearExpiry: Bool {
        let threshold: TimeInterval = 60
        return Date().addingTimeInterval(threshold) >= expiresAt
    }
}

/// Keychain keys for OAuth token storage.
public enum OAuthKeychainKey {
    public static let token = "youtube_oauth_token"
    public static let userCode = "youtube_oauth_user_code"
    public static let deviceCode = "youtube_oauth_device_code"
    public static let codeExpiresAt = "youtube_oauth_code_expires_at"
}

/// Stores and retrieves OAuthToken from Keychain.
public enum OAuthTokenStorage {

    public static func save(_ token: OAuthToken) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let string = data.base64EncodedString()
        Keychain.save(string, key: OAuthKeychainKey.token)
    }

    public static func load() -> OAuthToken? {
        guard let string = Keychain.load(key: OAuthKeychainKey.token),
              let data = Data(base64Encoded: string),
              let token = try? JSONDecoder().decode(OAuthToken.self, from: data) else {
            return nil
        }
        return token
    }

    public static func delete() {
        Keychain.delete(key: OAuthKeychainKey.token)
        Keychain.delete(key: OAuthKeychainKey.userCode)
        Keychain.delete(key: OAuthKeychainKey.deviceCode)
        Keychain.delete(key: OAuthKeychainKey.codeExpiresAt)
    }

    public static func saveDeviceCode(userCode: String, deviceCode: String, expiresAt: Date) {
        Keychain.save(userCode, key: OAuthKeychainKey.userCode)
        Keychain.save(deviceCode, key: OAuthKeychainKey.deviceCode)
        let expiryString = String(expiresAt.timeIntervalSince1970)
        Keychain.save(expiryString, key: OAuthKeychainKey.codeExpiresAt)
    }

    public static func loadDeviceCode() -> (userCode: String, deviceCode: String, expiresAt: Date)? {
        guard let userCode = Keychain.load(key: OAuthKeychainKey.userCode),
              let deviceCode = Keychain.load(key: OAuthKeychainKey.deviceCode),
              let expiryString = Keychain.load(key: OAuthKeychainKey.codeExpiresAt),
              let expiryTimestamp = Double(expiryString) else {
            return nil
        }
        return (userCode, deviceCode, Date(timeIntervalSince1970: expiryTimestamp))
    }

    public static func clearDeviceCode() {
        Keychain.delete(key: OAuthKeychainKey.userCode)
        Keychain.delete(key: OAuthKeychainKey.deviceCode)
        Keychain.delete(key: OAuthKeychainKey.codeExpiresAt)
    }
}

//
//  YouTubeOAuthDeviceFlow.swift
//  YouTubeSDK
//
//  Handles the OAuth 2.0 Device Authorization Grant flow.
//  https://developers.google.com/identity/protocols/oauth2/limited-input-device
//

import Foundation

// MARK: - Response Models

public struct DeviceCodeResponse: Codable, Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationUrl: String
    public let expiresIn: Int
    public let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUrl = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

public struct TokenResponse: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int
    public let scope: String
    public let tokenType: String
    public let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
        case idToken = "id_token"
    }

    public func toOAuthToken(fallbackRefreshToken: String? = nil) throws -> OAuthToken {
        guard let resolvedRefreshToken = refreshToken ?? fallbackRefreshToken else {
            throw OAuthError.invalidResponse
        }

        return OAuthToken(
            accessToken: accessToken,
            refreshToken: resolvedRefreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            scope: scope
        )
    }
}

public enum OAuthError: Error, LocalizedError, Sendable {
    case networkError(Error)
    case invalidResponse
    case expiredCode
    case slowDown(interval: Int)
    case authorizationPending
    case unknownError(String)
    case invalidClient
    case unauthorizedClient

    public var errorDescription: String? {
        switch self {
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .expiredCode:
            return "The code has expired. Please try again."
        case .slowDown(let interval):
            return "Slow down. Retry after \(interval) seconds."
        case .authorizationPending:
            return "Authorization pending. Please complete sign-in on another device."
        case .unknownError(let message):
            return "Unknown error: \(message)"
        case .invalidClient:
            return "Invalid client credentials."
        case .unauthorizedClient:
            return "Unauthorized client."
        }
    }
}

// MARK: - OAuth Device Flow

public actor YouTubeOAuthDeviceFlow {

    // OAuth credentials (SmartTube's TV app — for testing)
    private static let clientId = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    private static let clientSecret = "SboVhoG9s0rNafixCSGGKXAT"
    private static let scope = "http://gdata.youtube.com%20https://www.googleapis.com/auth/youtube-paid-content"

    private static let deviceCodeUrl = URL(string: "https://oauth2.googleapis.com/device/code")!
    private static let tokenUrl = URL(string: "https://oauth2.googleapis.com/token")!

    // MARK: - Step 1: Start Auth (Request Device Code)

    public func startAuth() async throws -> DeviceCodeResponse {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "scope", value: Self.scope)
        ]

        var request = URLRequest(url: Self.deviceCodeUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw OAuthError.unknownError("HTTP \(httpResponse.statusCode)")
        }

        guard let decoded = try? JSONDecoder().decode(DeviceCodeResponse.self, from: data) else {
            throw OAuthError.invalidResponse
        }

        print("[YouTubeSDK] Device auth started — user code: \(decoded.userCode)")
        return decoded
    }

    // MARK: - Step 2: Poll for Token

    public func pollForToken(deviceCode: String, interval: Int, expiresAt: Date) async throws -> OAuthToken {
        var attempt = 0

        while Date() < expiresAt {
            attempt += 1
            print("[YouTubeSDK] Polling for token (attempt \(attempt))...")

            let result = try await requestToken(code: deviceCode, grantType: nil)

            switch result {
            case .success(let token):
                print("[YouTubeSDK] Authorization received — token expires at \(token.expiresAt)")
                return token

            case .pending:
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            case .slowDown(let newInterval):
                print("[YouTubeSDK] Slow down — waiting \(newInterval)s")
                try await Task.sleep(nanoseconds: UInt64(newInterval) * 1_000_000_000)
            }
        }

        throw OAuthError.expiredCode
    }

    // MARK: - Token Request (Internal)

    private enum PollResult {
        case success(OAuthToken)
        case pending
        case slowDown(Int)
    }

    private func requestToken(code: String, grantType: String?, fallbackRefreshToken: String? = nil) async throws -> PollResult {
        var components = URLComponents()
        var queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "client_secret", value: Self.clientSecret)
        ]

        if let grantType = grantType {
            queryItems.append(URLQueryItem(name: "grant_type", value: grantType))
            queryItems.append(URLQueryItem(name: "refresh_token", value: code))
        } else {
            queryItems.append(URLQueryItem(name: "grant_type", value: "http://oauth.net/grant_type/device/1.0"))
            queryItems.append(URLQueryItem(name: "code", value: code))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: Self.tokenUrl)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.query?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorJson["error"] as? String {
                switch error {
                case "authorization_pending":
                    return .pending
                case "slow_down":
                    let interval = (errorJson["interval"] as? Int) ?? 5
                    return .slowDown(interval)
                case "invalid_grant", "expired_token":
                    throw OAuthError.expiredCode
                case "invalid_client":
                    throw OAuthError.invalidClient
                case "unauthorized_client":
                    throw OAuthError.unauthorizedClient
                default:
                    throw OAuthError.unknownError(error)
                }
            }
            throw OAuthError.invalidResponse
        }

        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw OAuthError.invalidResponse
        }

        return .success(try tokenResponse.toOAuthToken(fallbackRefreshToken: fallbackRefreshToken))
    }

    // MARK: - Token Refresh

    public func refreshToken(refreshToken: String) async throws -> OAuthToken {
        print("[YouTubeSDK] Refreshing token...")

        let result = try await requestToken(code: refreshToken, grantType: "refresh_token", fallbackRefreshToken: refreshToken)

        switch result {
        case .success(let token):
            print("[YouTubeSDK] Token refreshed successfully")
            return token
        default:
            throw OAuthError.invalidResponse
        }
    }

    // MARK: - Validate Token (Lightweight check)

    public func validateToken(accessToken: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/tokeninfo")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "access_token=\(accessToken)".data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let audience = json["aud"] as? String,
                   audience == Self.clientId {
                    return true
                }
            }
            return false
        } catch {
            return false
        }
    }
}

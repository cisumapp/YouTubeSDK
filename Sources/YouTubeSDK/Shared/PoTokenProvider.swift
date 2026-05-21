//
//  PoTokenProvider.swift
//  YouTubeSDK
//
//  Proof-of-Origin token provider protocol for YouTube streaming.
//  YouTube now requires poToken for playable streams (May 2026).
//

import Foundation

/// Protocol for providing Proof-of-Origin tokens for YouTube video playback.
/// Tokens are video-specific and typically expire after a few hours.
public protocol PoTokenProvider: Sendable {
    /// Fetches a poToken for the given video ID.
    /// - Parameter videoId: The YouTube video ID.
    /// - Returns: A base64-encoded poToken string.
    func token(for videoId: String) async throws -> String
}

/// Server-based poToken provider for use with self-hosted token services.
/// Compatible with: https://github.com/iv-org/youtube-trusted-session-generator
public struct ServerPoTokenProvider: PoTokenProvider {
    private let serviceURL: URL
    private let session: URLSession

    public init(serviceURL: URL, session: URLSession = .shared) {
        self.serviceURL = serviceURL
        self.session = session
    }

    public func token(for videoId: String) async throws -> String {
        let endpoint = serviceURL.appendingPathComponent("token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["videoId": videoId])
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "YouTubeSDK", code: code, userInfo: [NSLocalizedDescriptionKey: "poToken server returned HTTP \(code)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            throw NSError(domain: "YouTubeSDK", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid poToken response format"])
        }

        return token
    }
}
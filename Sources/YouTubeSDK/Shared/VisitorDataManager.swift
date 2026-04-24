//
//  VisitorDataManager.swift
//  YouTubeSDK
//
//  Created by GitHub Copilot on behalf of user.
//

import Foundation

/// Manages fetching and caching of YouTube's `visitorData` token.
public actor VisitorDataManager {

    private var visitorData: String?
    private var fetchedAt: Date?
    private let ttl: TimeInterval = 20 * 60 // 20 minutes
    private let network: NetworkClient

    /// Creates a new manager. Uses the provided session and client preset.
    public init(session: URLSession = .shared, client: ClientConfig = .web, cookies: String? = nil) {
        let context = InnerTubeContext(client: client, cookies: cookies)
        self.network = NetworkClient(context: context, session: session, baseURL: YouTubeSDKConstants.URLS.API.youtubeInnerTubeURL)
    }

    /// Returns fresh visitorData, fetching from the API when necessary.
    public func getVisitorData() async throws -> String? {
        if let v = visitorData, let fetched = fetchedAt, Date().timeIntervalSince(fetched) < ttl {
            return v
        }

        let body: [String: Any] = [
            "context": [
                "client": [
                    "clientName": ClientConfig.web.name,
                    "clientVersion": ClientConfig.web.version
                ]
            ]
        ]

        let data = try await network.sendComplexRequest("visitor_id", body: body)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseContext = json["responseContext"] as? [String: Any],
              let visitor = responseContext["visitorData"] as? String else {
            return nil
        }

        self.visitorData = visitor
        self.fetchedAt = Date()
        return visitor
    }

    /// Clears cached visitor token.
    public func invalidate() {
        visitorData = nil
        fetchedAt = nil
    }
}

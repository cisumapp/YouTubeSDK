//
//  YouTubeMusicClient.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

public actor YouTubeMusicClient {

    let network: NetworkClient
    let cookies: String?
    let accessToken: String?

    /// Initializes the Client.
    /// - Parameters:
    ///   - cookies: Optional "Cookie" header string. If provided, requests will be authenticated via cookies.
    ///   - accessToken: Optional OAuth Bearer token. If provided, requests will be authenticated via OAuth.
    public init(cookies: String? = nil, accessToken: String? = nil) {
        self.cookies = cookies
        self.accessToken = accessToken
        let context = InnerTubeContext(client: ClientConfig.webRemix, cookies: cookies, accessToken: accessToken)
        self.network = NetworkClient(context: context, baseURL: YouTubeSDKConstants.URLS.API.youtubeMusicInnerTubeURL)
    }

    public func search(_ query: String) async throws -> [YouTubeMusicSong] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return [] }

        if let fallbackSongs = try? await searchViaYouTube(normalizedQuery), !fallbackSongs.isEmpty {
            YouTubeDebugLogger.log("YouTubeMusic search used generic YouTube fallback for query=\"\(normalizedQuery)\"")
            return fallbackSongs
        }

        let data = try await network.get("search", body: ["query": normalizedQuery])
        return parseMusicItems(from: data)
    }

    private func searchViaYouTube(_ query: String) async throws -> [YouTubeMusicSong] {
        let youtube = YouTubeClient(cookies: cookies, accessToken: accessToken)
        let continuation = try await youtube.search(query)

        return continuation.items.compactMap { item in
            if case .song(let song) = item {
                return song
            }
            return nil
        }
    }
    
    public func getSearchSuggestions(query: String) async throws -> [String] {
        let body = ["input": query]
        let data = try await network.get("music/get_search_suggestions", body: body)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        
        let suggestions = findAll(key: "searchSuggestionRenderer", in: json)
        return suggestions.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            
            // Try both parsing styles found in discovery
            if let nav = dict["navigationEndpoint"] as? [String: Any],
               let search = nav["searchEndpoint"] as? [String: Any],
               let query = search["query"] as? String {
                return query
            }
            
            if let sugg = dict["suggestion"] as? [String: Any],
               let runs = sugg["runs"] as? [[String: Any]] {
                return runs.compactMap { $0["text"] as? String }.joined()
            }
            
            return nil
        }
    }
}

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

    // MARK: - Search
    
    /// Searches for music matching the query.
    /// This method is nonisolated to ensure the query string is deep-copied on the
    /// caller's executor *before* crossing the actor boundary.
    nonisolated public func search(_ query: String) async throws -> [YouTubeMusicSong] {
        if Task.isCancelled { throw CancellationError() }

        // Force a deep, native Swift copy of the string to break any dangerous bridging
        let safeQuery = String(data: Data(query.utf8), encoding: .utf8) ?? ""
        
        let ws = CharacterSet(charactersIn: " \t\r\n\u{000B}\u{000C}\u{0085}\u{00A0}\u{1680}\u{180E}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")
        let normalizedQuery = safeQuery.trimmingCharacters(in: ws)
        
        if normalizedQuery.isEmpty { return [] }

        return try await performSearch(normalizedQuery)
    }

    private func performSearch(_ normalizedQuery: String) async throws -> [YouTubeMusicSong] {
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

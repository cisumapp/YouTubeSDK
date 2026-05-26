//
//  YouTubeClient.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

public actor YouTubeClient {
    let network: NetworkClient
    let playerNetwork: NetworkClient
    let webSearchNetwork: NetworkClient
    let cookies: String?
    let accessToken: String?
    let visitorManager: VisitorDataManager
    let poTokenProvider: PoTokenProvider?
    let innerTube: InnerTubeAPI

    // poToken cache - video-specific, expires after hours
    private var cachedPoToken: String?
    private var cachedPoTokenVideoId: String?
    private var cachedPoTokenExpiry: Date?

    /// Initializes the Client.
    /// - Parameters:
    ///   - cookies: Optional "Cookie" header string. If provided, requests will be authenticated via cookies.
    ///   - accessToken: Optional OAuth Bearer token. If provided, requests will be authenticated via OAuth.
    ///   - poTokenProvider: Optional poToken provider. Required for YouTube streams as of May 2026.
    public init(cookies: String? = nil, accessToken: String? = nil, poTokenProvider: PoTokenProvider? = nil) {
        self.cookies = cookies
        self.accessToken = accessToken
        self.poTokenProvider = poTokenProvider
        self.innerTube = InnerTubeAPI(authToken: accessToken, poTokenProvider: poTokenProvider)
        let context = InnerTubeContext(client: ClientConfig.ios, cookies: nil, accessToken: nil)
        let webContext = InnerTubeContext(client: ClientConfig.web, cookies: cookies, accessToken: accessToken)
        self.network = NetworkClient(context: context)
        self.playerNetwork = NetworkClient(context: context, baseURL: "https://youtubei.googleapis.com/youtubei/v1")
        self.webSearchNetwork = NetworkClient(context: webContext)
        self.visitorManager = VisitorDataManager(session: .shared, client: ClientConfig.web, cookies: cookies)
    }

    /// Returns a valid poToken for the given video ID, fetching if necessary.
    private func getPoToken(for videoId: String) async -> String? {
        // Return cached token if valid for this video
        if cachedPoToken != nil, cachedPoTokenVideoId == videoId,
           let expiry = cachedPoTokenExpiry, expiry > Date() {
            return cachedPoToken
        }

        // Try to fetch new token
        if let provider = poTokenProvider, let token = try? await provider.token(for: videoId) {
            cachedPoToken = token
            cachedPoTokenVideoId = videoId
            cachedPoTokenExpiry = Date().addingTimeInterval(6 * 3600) // 6 hour expiry
            return token
        }

        return nil
    }

    // MARK: - Browsing
    
    public func getHome(
        regionCode: String? = nil,
        languageCode: String? = nil,
        musicOnly: Bool = false
    ) async throws -> YouTubeContinuation<YouTubeItem> {
        let searchNetwork = makeWebSearchNetwork(regionCode: regionCode, languageCode: languageCode)

        // Home parsing is tuned to WEB browse payloads (rich wrappers and continuation shape).
        let data = try await browseHomeData(regionCode: regionCode, languageCode: languageCode)
        var parsedHome = parseContinuationResults(from: data)
        if musicOnly {
            parsedHome = filteredMusicContinuation(parsedHome)
        }
        if !parsedHome.items.isEmpty {
            return parsedHome
        }
        print("[YouTubeSDK] getHome: parsed empty items from data (len=\(data.count))")

        // Logged-out/low-history accounts can receive a feed nudge with no items.
        // Fall back so client UIs are not left completely empty.
        let fallbackQuery = makeRegionalMusicFallbackQuery(regionCode: regionCode)
        if let searchFallbackData = try? await searchNetwork.get("search", body: ["query": fallbackQuery]) {
            var parsedSearchFallback = parseContinuationResults(from: searchFallbackData)
            if musicOnly {
                parsedSearchFallback = filteredMusicContinuation(parsedSearchFallback)
            }
            if !parsedSearchFallback.items.isEmpty {
                return parsedSearchFallback
            }
        }

        if let trendingVideos = try? await getTrending(), !trendingVideos.isEmpty {
            var trendingFallback = YouTubeContinuation(
                items: trendingVideos.map { YouTubeItem.video($0) },
                continuationToken: nil
            )

            if musicOnly {
                trendingFallback = filteredMusicContinuation(trendingFallback)
            }

            if !trendingFallback.items.isEmpty {
                return trendingFallback
            }
        }

        return parsedHome
    }
    
    public func getTrending() async throws -> [YouTubeVideo] {
        let data = try await browseData(body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.trending])
        return parseVideos(from: data)
    }
    
    public func getChannelVideos(channelId: String) async throws -> [YouTubeVideo] {
        let data = try await browseData(body: ["browseId": channelId, "params": "EgZ2aWRlb3M%3D"])
        return parseVideos(from: data)
    }
    
    public func getPlaylist(id: String) async throws -> YouTubeContinuation<YouTubeItem> {
        let browseId = id.hasPrefix("PL") ? "VL\(id)" : id
        let data = try await browseData(body: ["browseId": browseId])
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { 
            throw YouTubeError.parsingError(details: "Invalid JSON response for playlist")
        }
        
        let videosRaw = findAll(key: YouTubeSDKConstants.InternalKeys.Renderers.playlistVideo, in: json)
        let items = videosRaw.compactMap { item -> YouTubeItem? in
            guard let dict = item as? [String: Any],
                  let video = YouTubeVideo(from: dict) else { return nil }
            return .video(video)
        }
        
        let token = findContinuationToken(in: json)
        return YouTubeContinuation(items: items, continuationToken: token)
    }

    // MARK: - Search
    
    /// Searches for videos, channels, and playlists matching the query.
    /// This method is nonisolated to ensure the query string is deep-copied on the
    /// caller's executor *before* crossing the actor boundary. This prevents EXC_BAD_ACCESS
    /// crashes caused by passing bridged, mutable, or short-lived strings (e.g. from SwiftUI)
    /// directly into an asynchronous actor context.
    nonisolated public func search(_ query: String) async throws -> YouTubeContinuation<YouTubeItem> {
        // 1. Guard against cancellation early.
        if Task.isCancelled { throw CancellationError() }

        // 2. Force a deep, native Swift copy of the string.
        // `String(query)` can sometimes preserve the Objective-C bridging.
        // Converting to UTF-8 and back guarantees a brand new native memory buffer
        // that is 100% safe to pass across actor boundaries.
        let safeQuery = String(data: Data(query.utf8), encoding: .utf8) ?? ""
        
        // 3. Early exit for empty input to avoid further processing.
        if safeQuery.isEmpty {
            return YouTubeContinuation(items: [], continuationToken: nil)
        }

        // 4. Use a manually created CharacterSet instance for maximum stability.
        let ws = CharacterSet(charactersIn: " \t\r\n\u{000B}\u{000C}\u{0085}\u{00A0}\u{1680}\u{180E}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")
        let normalizedQuery = safeQuery.trimmingCharacters(in: ws)
        
        if normalizedQuery.isEmpty {
            return YouTubeContinuation(items: [], continuationToken: nil)
        }

        // 5. Forward the safe, native string to the actor-isolated method.
        return try await performSearch(normalizedQuery)
    }

    private func performSearch(_ normalizedQuery: String) async throws -> YouTubeContinuation<YouTubeItem> {
        // Snapshot actor state to ensure consistency across the await boundary.
        let network = self.webSearchNetwork
        let currentCookies = self.cookies
        let currentToken = self.accessToken

        do {
            let data = try await network.get("search", body: ["query": normalizedQuery])
            return parseContinuationResults(from: data)
        } catch {
            // Fallback to Android client if Web search fails (e.g. throttled).
            YouTubeDebugLogger.log("Web search failed, trying Android fallback for: \(normalizedQuery)")
            
            let androidContext = InnerTubeContext(
                client: ClientConfig.android,
                cookies: currentCookies,
                accessToken: currentToken
            )
            let androidNetwork = NetworkClient(context: androidContext)

            if let fallbackData = try? await androidNetwork.get("search", body: ["query": normalizedQuery]) {
                return parseContinuationResults(from: fallbackData)
            }

            throw error
        }
    }

    // MARK: - Video (SmartTubeIOS-style — Exhaustive Multi-Client)

    /// Fetches video player info using the smart stream resolver.
    /// Orchestrates InnerTube multi-client fallbacks and high-quality WebView extraction.
    /// Matches SmartTubeIOS's robust playback resolution strategy.
    public func video(id: String) async throws -> YouTubeVideo {
        return try await resolveVideoSmart(id: id)
    }
    
    /// Resolves a playable stream for the given video ID.
    /// Returns the core PlayerInfo model which includes solved n-parameters and multi-client results.
    public func resolveVideo(id: String, preferAudio: Bool = false) async throws -> PlayerInfo {
        return try await YouTubeStreamResolver.shared.resolve(videoId: id, preferAudio: preferAudio, api: self.innerTube)
    }

    // MARK: - Search Suggestions

    /// Fetches search suggestions for Main YouTube using an external suggest endpoint.
    /// - Parameter query: The search term.
    /// - Returns: A list of suggested search terms.
    public func getSearchSuggestions(query: String, baseURL: String = YouTubeSDKConstants.URLS.API.youtubeSuggestionsURL) async throws -> [String] {
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
        var components = URLComponents(url: url.appendingPathComponent("search"), resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "q", value: query)
        ]
        
        guard let url = components?.url else { return [] }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let responseString = String(data: data, encoding: .utf8) else { return [] }
        
        // The response is JSONP: window.google.ac.h(["query", [["suggestion", ...]]])
        guard let startBracket = responseString.firstIndex(of: "["),
              let endBracket = responseString.lastIndex(of: "]") else {
            return []
        }
        
        let jsonString = String(responseString[startBracket...endBracket])
        guard let jsonArray = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [Any],
              jsonArray.count > 1,
              let suggestionsArray = jsonArray[1] as? [[Any]] else {
            return []
        }
        
        return suggestionsArray.compactMap { $0.first as? String }
    }
    
    /// Fetches an AI-powered summary of the video (if available).
    public func getVideoSummary(videoId: String) async throws -> YouTubeAISummary {
        let body: [String: String] = [
            "videoId": videoId,
            "engagementPanelType": "ENGAGEMENT_PANEL_TYPE_YOU_CHAT"
        ]
        let data = try await network.get("get_panel", body: body)
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = YouTubeAISummary(from: json) else {
            throw YouTubeError.apiError(message: "AI Summary not available for this video.")
        }
        return summary
    }
}

extension YouTubeClient {
    func filteredMusicContinuation(_ continuation: YouTubeContinuation<YouTubeItem>) -> YouTubeContinuation<YouTubeItem> {
        let filteredItems = continuation.items.filter { shouldKeepMusicHomeItem($0) }
        return YouTubeContinuation(items: filteredItems, continuationToken: continuation.continuationToken)
    }

    func makeWebSearchNetwork(regionCode: String?, languageCode: String?) -> NetworkClient {
        guard let normalizedRegion = normalizedRegionCode(regionCode) else {
            return webSearchNetwork
        }

        let normalizedLanguage = normalizedLanguageCode(languageCode)
        let context = InnerTubeContext(
            client: ClientConfig.web,
            cookies: cookies,
            gl: normalizedRegion,
            hl: normalizedLanguage
        )
        return NetworkClient(context: context)
    }

    private func browseHomeData(regionCode: String?, languageCode: String?) async throws -> Data {
        let body = ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.home]
        do {
            return try await makeWebSearchNetwork(regionCode: regionCode, languageCode: languageCode).get("browse", body: body)
        } catch {
            let fallback = NetworkClient(
                context: InnerTubeContext(client: ClientConfig.ios, cookies: cookies, accessToken: accessToken),
                baseURL: "https://youtubei.googleapis.com/youtubei/v1"
            )
            return try await fallback.get("browse", body: body)
        }
    }

    private func browseData(body: [String: String]) async throws -> Data {
        do {
            return try await network.get("browse", body: body)
        } catch {
            let fallback = NetworkClient(
                context: InnerTubeContext(client: ClientConfig.ios, cookies: cookies, accessToken: accessToken),
                baseURL: "https://youtubei.googleapis.com/youtubei/v1"
            )
            return try await fallback.get("browse", body: body)
        }
    }

    nonisolated func shouldKeepMusicHomeItem(_ item: YouTubeItem) -> Bool {
        switch item {
        case .song:
            return true
        case .playlist(let playlist):
            return isLikelyMusicMetadata(title: playlist.title, secondaryText: playlist.author)
        case .video(let video):
            return isLikelyMusicMetadata(title: video.title, secondaryText: video.author)
        case .channel(let channel):
            return isLikelyArtistChannelName(channel.title)
        case .shelf(let shelf):
            return isLikelyMusicMetadata(title: shelf.title, secondaryText: nil)
        }
    }

    nonisolated func makeRegionalMusicFallbackQuery(regionCode: String?) -> String {
        if let normalizedRegion = normalizedRegionCode(regionCode) {
            return "top music videos \(normalizedRegion)"
        }
        return "top music videos"
    }

    nonisolated func normalizedRegionCode(_ rawRegionCode: String?) -> String? {
        guard let raw = rawRegionCode, !raw.isEmpty else { return nil }
        let ws = CharacterSet(charactersIn: " \t\r\n")
        let trimmed = raw.trimmingCharacters(in: ws)
        if trimmed.isEmpty { return nil }
        
        let uppercased = trimmed.uppercased()
        guard uppercased.count == 2 else { return nil }
        return uppercased
    }

    nonisolated func normalizedLanguageCode(_ rawLanguageCode: String?) -> String {
        guard let raw = rawLanguageCode, !raw.isEmpty else { return "en" }
        let ws = CharacterSet(charactersIn: " \t\r\n")
        let trimmed = raw.trimmingCharacters(in: ws)
        if trimmed.isEmpty { return "en" }

        if let separator = trimmed.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(trimmed[..<separator]).lowercased()
        }

        return trimmed.lowercased()
    }

    nonisolated func isLikelyArtistChannelName(_ channelName: String) -> Bool {
        let normalized = channelName.lowercased()
        let trustedSignals = [
            "official artist channel",
            "- topic",
            "vevo",
            "records",
            "music",
            "band",
            "orchestra"
        ]
        return trustedSignals.contains { normalized.contains($0) }
    }

    nonisolated func isLikelyMusicMetadata(title: String, secondaryText: String?) -> Bool {
        let normalizedTitle = title.lowercased()
        let normalizedSecondary = secondaryText?.lowercased() ?? ""
        let merged = "\(normalizedTitle) \(normalizedSecondary)"

        let blockedSignals = [
            "#shorts",
            "/shorts/",
            "tutorial",
            "gameplay",
            "gaming",
            "reaction",
            "review",
            "podcast",
            "interview"
        ]
        if blockedSignals.contains(where: { merged.contains($0) }) {
            return false
        }

        let positiveSignals = [
            "official music video",
            "official video",
            "official audio",
            "lyric",
            "lyrics",
            "visualizer",
            "audio",
            "song",
            "album",
            "single",
            "remix",
            "acoustic",
            "feat.",
            "ft.",
            "vevo",
            "topic"
        ]

        if positiveSignals.contains(where: { merged.contains($0) }) {
            return true
        }

        return isLikelyArtistChannelName(secondaryText ?? "")
    }
}

//
//  YouTubeClient.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

public actor YouTubeClient {
    let network: NetworkClient
    let webSearchNetwork: NetworkClient
    let cookies: String?
    
    /// Initializes the Client.
    /// - Parameter cookies: Optional "Cookie" header string. If provided, requests will be authenticated.
    public init(cookies: String? = nil) {
        self.cookies = cookies
        let context = InnerTubeContext(client: ClientConfig.ios, cookies: cookies)
        let webContext = InnerTubeContext(client: ClientConfig.web, cookies: cookies)
        self.network = NetworkClient(context: context)
        self.webSearchNetwork = NetworkClient(context: webContext)
    }

    // MARK: - Browsing
    
    public func getHome(
        regionCode: String? = nil,
        languageCode: String? = nil,
        musicOnly: Bool = false
    ) async throws -> YouTubeContinuation<YouTubeItem> {
        let searchNetwork = makeWebSearchNetwork(regionCode: regionCode, languageCode: languageCode)

        // Home parsing is tuned to WEB browse payloads (rich wrappers and continuation shape).
        let data = try await searchNetwork.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.home])
        var parsedHome = parseContinuationResults(from: data)
        if musicOnly {
            parsedHome = filteredMusicContinuation(parsedHome)
        }
        if !parsedHome.items.isEmpty {
            return parsedHome
        }

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
        let data = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.trending])
        return await parseVideos(from: data)
    }
    
    public func getChannelVideos(channelId: String) async throws -> [YouTubeVideo] {
        let data = try await network.get("browse", body: ["browseId": channelId, "params": "EgZ2aWRlb3M%3D"])
        return await parseVideos(from: data)
    }
    
    public func getPlaylist(id: String) async throws -> YouTubeContinuation<YouTubeVideo> {
        let browseId = id.hasPrefix("PL") ? "VL\(id)" : id
        let data = try await network.get("browse", body: ["browseId": browseId])
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { 
            throw YouTubeError.parsingError(details: "Invalid JSON response for playlist")
        }
        
        let videosRaw = await findAll(key: YouTubeSDKConstants.InternalKeys.Renderers.playlistVideo, in: json)
        let videos = videosRaw.compactMap { item -> YouTubeVideo? in
            guard let dict = item as? [String: Any] else { return nil }
            return YouTubeVideo(from: dict)
        }
        
        let token = await findContinuationToken(in: json)
        return YouTubeContinuation(items: videos, continuationToken: token)
    }

    public func search(_ query: String) async throws -> YouTubeContinuation<YouTubeItem> {
        let data = try await webSearchNetwork.get("search", body: ["query": query])
//        let diagnostics = diagnoseSearchResponse(from: data)
//        print("yt_search_diagnostics client=WEB \(diagnostics.summary)")
//        writeSearchDebugDump(data, clientName: "web")

        return parseContinuationResults(from: data)
    }

//    public func writeSearchDebugDump(_ data: Data, clientName: String) {
//        let timestamp = Int(Date().timeIntervalSince1970)
//        let tempFile = "yt_search_debug_\(clientName)_\(timestamp).json"
//        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tempFile)
//
//        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
//              let debugData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted) else {
//            return
//        }
//
//        try? debugData.write(to: tempURL, options: .atomic)
//        print("yt_search_debug client=\(clientName) saved=\(tempURL.path)")
//    }

    /// Fetches the full video details.
    /// - Parameters:
    ///   - id: The video ID.
    ///   - decipher: Whether to resolve encrypted signature and 'n' parameters. Set to false for metadata-only prefetching.
    public func video(id: String, decipher: Bool = true) async throws -> YouTubeVideo {
        let data = try await network.get("player", body: ["videoId": id])
        
        let decoder = JSONDecoder()
        var video = try decoder.decode(YouTubeVideo.self, from: data)
        
        if decipher, var streamingData = video.streamingData {


            // 1. Process Adaptive Formats
            var newAdaptive: [Stream] = []
            // Limit deciphering to the first few streams (usually the highest quality) to avoid JS overhead
            for var stream in streamingData.adaptiveFormats.prefix(5) {
                if let cipher = stream.signatureCipher {
                    do {
                        let decryptedURL = try await Cipher.shared.decipher(url: stream.url ?? "", signatureCipher: cipher, network: network)
                        stream.url = decryptedURL.absoluteString
                        stream.signatureCipher = nil
                    } catch {
                        print("⚠️ Failed to decipher signature: \(error)")
                    }
                } else if let url = stream.url {
                    do {
                        let decryptedURL = try await Cipher.shared.decipherN(url: url, network: network)
                        stream.url = decryptedURL.absoluteString
                    } catch {
                        print("⚠️ Failed to decipher 'n' parameter: \(error)")
                    }
                }
                newAdaptive.append(stream)
            }
            streamingData.adaptiveFormats = newAdaptive
            
            // 2. Process Muxed Formats
            var newFormats: [Stream] = []
            for var stream in streamingData.formats.prefix(3) {
                if let cipher = stream.signatureCipher {
                    do {
                        let decryptedURL = try await Cipher.shared.decipher(url: stream.url ?? "", signatureCipher: cipher, network: network)
                        stream.url = decryptedURL.absoluteString
                        stream.signatureCipher = nil
                    } catch {
                        print("⚠️ Failed to decipher signature: \(error)")
                    }
                } else if let url = stream.url {
                    do {
                        let decryptedURL = try await Cipher.shared.decipherN(url: url, network: network)
                        stream.url = decryptedURL.absoluteString
                    } catch {
                        print("⚠️ Failed to decipher 'n' parameter: \(error)")
                    }
                }
                newFormats.append(stream)
            }
            streamingData.formats = newFormats
            
            video.streamingData = streamingData
        }
        return video
    }


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
        guard let raw = rawRegionCode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let uppercased = raw.uppercased()
        guard uppercased.count == 2 else { return nil }
        return uppercased
    }

    nonisolated func normalizedLanguageCode(_ rawLanguageCode: String?) -> String {
        guard let raw = rawLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "en"
        }

        if let separator = raw.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(raw[..<separator]).lowercased()
        }

        return raw.lowercased()
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

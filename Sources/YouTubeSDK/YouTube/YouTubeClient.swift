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

    // poToken cache - video-specific, expires after hours
    private var cachedPoToken: String?
    private var cachedPoTokenVideoId: String?
    private var cachedPoTokenExpiry: Date?

    /// Limits concurrent player requests to avoid rate limiting / bot detection.
    private var activePlayerRequests = 0
    private let maxPlayerRequests = 1
    private var playerRequestWaiters: [CheckedContinuation<Void, Never>] = []

    /// Initializes the Client.
    /// - Parameters:
    ///   - cookies: Optional "Cookie" header string. If provided, requests will be authenticated via cookies.
    ///   - accessToken: Optional OAuth Bearer token. If provided, requests will be authenticated via OAuth.
    ///   - poTokenProvider: Optional poToken provider. Required for YouTube streams as of May 2026.
    public init(cookies: String? = nil, accessToken: String? = nil, poTokenProvider: PoTokenProvider? = nil) {
        self.cookies = cookies
        self.accessToken = accessToken
        self.poTokenProvider = poTokenProvider
        let context = InnerTubeContext(client: ClientConfig.ios, cookies: nil, accessToken: nil)
        let webContext = InnerTubeContext(client: ClientConfig.web, cookies: cookies, accessToken: accessToken)
        self.network = NetworkClient(context: context)
        self.playerNetwork = NetworkClient(context: context, baseURL: YouTubeSDKConstants.URLS.API.googleapisInnerTubeURL)
        self.webSearchNetwork = NetworkClient(context: webContext)
        self.visitorManager = VisitorDataManager(session: .shared, client: ClientConfig.web, cookies: cookies)
    }

    /// Returns a valid poToken for the given video ID, fetching if necessary.
    private func getPoToken(for videoId: String) async -> String? {
        // Return cached token if valid for this video
        if cachedPoToken != nil, cachedPoTokenVideoId == videoId,
           let expiry = cachedPoTokenExpiry, expiry > Date()
        {
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

    private func waitForPlayerSlot() async {
        if activePlayerRequests < maxPlayerRequests {
            activePlayerRequests += 1
            return
        }
        await withCheckedContinuation { continuation in
            playerRequestWaiters.append(continuation)
        }
    }

    private func releasePlayerSlot() {
        if let next = playerRequestWaiters.first {
            playerRequestWaiters.removeFirst()
            next.resume()
        } else {
            activePlayerRequests -= 1
        }
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

    public func getPlaylist(id: String) async throws -> YouTubeContinuation<YouTubeVideo> {
        let browseId = id.hasPrefix("PL") ? "VL\(id)" : id
        let data = try await browseData(body: ["browseId": browseId])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeError.parsingError(details: "Invalid JSON response for playlist")
        }

        let videosRaw = findAll(key: YouTubeSDKConstants.InternalKeys.Renderers.playlistVideo, in: json)
        let videos = videosRaw.compactMap { item -> YouTubeVideo? in
            guard let dict = item as? [String: Any] else { return nil }
            return YouTubeVideo(from: dict)
        }

        let token = findContinuationToken(in: json)
        return YouTubeContinuation(items: videos, continuationToken: token)
    }

    public func search(_ query: String) async throws -> YouTubeContinuation<YouTubeItem> {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return YouTubeContinuation(items: [], continuationToken: nil)
        }

        do {
            let data = try await webSearchNetwork.get("search", body: ["query": normalizedQuery])
            return parseContinuationResults(from: data)
        } catch {
            let androidNetwork = NetworkClient(
                context: InnerTubeContext(client: ClientConfig.android, cookies: cookies, accessToken: accessToken)
            )

            if let fallbackData = try? await androidNetwork.get("search", body: ["query": normalizedQuery]) {
                YouTubeDebugLogger.log("search fallback used Android client for query=\"\(normalizedQuery)\"")
                return parseContinuationResults(from: fallbackData)
            }

            throw error
        }
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

    // MARK: - Video (SmartTubeIOS-style — no decipher)

    /// Fetches video player info using the iOS client (primary).
    /// Does NOT do exhaustive retry — the ViewModel handles that.
    /// Matches SmartTubeIOS's `fetchPlayerInfo(videoId:)` approach.
    public func video(id: String) async throws -> YouTubeVideo {
        await waitForPlayerSlot()
        defer { releasePlayerSlot() }

        let visitor = try? await visitorManager.getVisitorData()

        // Fetch poToken if provider is configured
        let poToken = await getPoToken(for: id)

        let body: [String: Any] = [
            "videoId": id,
            "racyCheckOk": true,
            "contentCheckOk": true,
        ]

        // iOS client on googleapis.com — matches SmartTubeIOS's postPlayer()
        let contextWithPoToken = InnerTubeContext(
            client: ClientConfig.ios,
            cookies: nil,
            accessToken: nil,
            poToken: poToken
        )
        let iosPlayerNetwork = NetworkClient(
            context: contextWithPoToken,
            baseURL: YouTubeSDKConstants.URLS.API.googleapisInnerTubeURL
        )

        let data = try await iosPlayerNetwork.sendWithVisitorData(
            "player",
            body: NetworkClient.SendableBody(body),
            visitorData: visitor
        )

        let decoder = JSONDecoder()
        let video = try decoder.decode(YouTubeVideo.self, from: data)

        if let sd = video.streamingData {
            let audioCount = sd.adaptiveFormats.count(where: { $0.isAudioOnly && $0.playbackUrl != nil })
            let muxedCount = sd.formats.count(where: { $0.playbackUrl != nil })
            let hasHLS = sd.hlsManifestUrl != nil
            print("[YouTubeSDK] iOS player result for \(id): audio=\(audioCount) muxed=\(muxedCount) hls=\(hasHLS) adaptive=\(sd.adaptiveFormats.count)")
        } else {
            print("[YouTubeSDK] iOS player: NO streamingData for \(id)")
        }

        return video
    }

    /// Fetches video using the Android client (fallback).
    /// Android returns muxed formats (itag 18/22) that iOS omits.
    /// Matches SmartTubeIOS's `fetchPlayerInfoAndroid(videoId:)`.
    public func videoAndroid(id: String) async throws -> YouTubeVideo {
        await waitForPlayerSlot()
        defer { releasePlayerSlot() }

        let body: [String: Any] = [
            "videoId": id,
            "racyCheckOk": true,
            "contentCheckOk": true,
        ]

        // Android client on googleapis.com — matches SmartTubeIOS's postAndroid()
        let androidNetwork = NetworkClient(
            context: InnerTubeContext(client: ClientConfig.android),
            baseURL: YouTubeSDKConstants.URLS.API.googleapisInnerTubeURL
        )

        let data = try await androidNetwork.sendWithVisitorData(
            "player",
            body: NetworkClient.SendableBody(body)
        )

        let decoder = JSONDecoder()
        let video = try decoder.decode(YouTubeVideo.self, from: data)

        if let sd = video.streamingData {
            let audioCount = sd.adaptiveFormats.count(where: { $0.isAudioOnly && $0.playbackUrl != nil })
            let muxedCount = sd.formats.count(where: { $0.playbackUrl != nil })
            let hasHLS = sd.hlsManifestUrl != nil
            print("[YouTubeSDK] Android player result for \(id): audio=\(audioCount) muxed=\(muxedCount) hls=\(hasHLS) adaptive=\(sd.adaptiveFormats.count)")
        } else {
            print("[YouTubeSDK] Android player: NO streamingData for \(id)")
        }

        return video
    }

    /// Fetches video using the authenticated TV client (fallback for auth-required videos).
    /// Matches SmartTubeIOS's `fetchPlayerInfoAuthenticated(videoId:)`.
    public func videoTV(id: String) async throws -> YouTubeVideo {
        await waitForPlayerSlot()
        defer { releasePlayerSlot() }

        let body: [String: Any] = [
            "videoId": id,
            "racyCheckOk": true,
            "contentCheckOk": true,
        ]

        let tvNetwork = NetworkClient(
            context: InnerTubeContext(client: ClientConfig.tv, cookies: cookies, accessToken: accessToken),
            baseURL: YouTubeSDKConstants.URLS.API.googleapisInnerTubeURL
        )

        let data = try await tvNetwork.sendWithVisitorData(
            "player",
            body: NetworkClient.SendableBody(body)
        )

        let decoder = JSONDecoder()
        let video = try decoder.decode(YouTubeVideo.self, from: data)

        if let sd = video.streamingData {
            let muxedCount = sd.formats.count(where: { $0.playbackUrl != nil })
            let hasHLS = sd.hlsManifestUrl != nil
            print("[YouTubeSDK] TV player result for \(id): muxed=\(muxedCount) hls=\(hasHLS)")
        }

        return video
    }

    // MARK: - Old Decipher-Based Flow (Commented Out)

    // The entire decipher engine + multi-client fallback chain is preserved below.
    // All logs confirm cipher=nil and no 'n' param on every stream — the engine does nothing.
    // Re-enable if YouTube ever re-introduces cipher-protected URLs.

    /*
     /// Old video() with decipher parameter — replaced by SmartTubeIOS-style approach above.
     public func video_old_decipher(id: String, decipher: Bool = true) async throws -> YouTubeVideo {
         await waitForPlayerSlot()

         let visitor = try? await visitorManager.getVisitorData()
         await Cipher.shared.ensureEngineReady(network: network)

         let poToken = await getPoToken(for: id)
         if let poToken = poToken {
             print("DECIPHER ENGINE: Using poToken for video \(id)")
         }

         let body: [String: Any] = [
             "videoId": id,
             "racyCheckOk": true,
             "contentCheckOk": true
         ]

         var video: YouTubeVideo
         do {
             let contextWithPoToken = InnerTubeContext(
             client: ClientConfig.ios,
             cookies: nil,
             accessToken: nil,
             poToken: poToken
         )
             let networkWithPoToken = NetworkClient(context: contextWithPoToken, baseURL: YouTubeSDKConstants.URLS.API.googleapisInnerTubeURL)
             video = try await fetchAndDecipher(id: id, body: body, network: networkWithPoToken, visitor: visitor, decipher: decipher)

             if decipher, !hasPlayableStreams(video) {
                 let webNetwork = NetworkClient(context: InnerTubeContext(client: ClientConfig.web, cookies: cookies, accessToken: nil))
                 if let fallback = try? await fetchAndDecipher(id: id, body: body, network: webNetwork, visitor: nil, decipher: decipher) {
                     video = mergeStreams(into: video, from: fallback)
                 }
             }

             if decipher, !hasPlayableStreams(video) {
                 let iosMusicNetwork = NetworkClient(context: InnerTubeContext(client: ClientConfig.iosMusic, cookies: cookies, accessToken: nil))
                 if let fallback = try? await fetchAndDecipher(id: id, body: body, network: iosMusicNetwork, visitor: nil, decipher: decipher) {
                     video = mergeStreams(into: video, from: fallback)
                 }
             }

             if decipher, !hasPlayableStreams(video) {
                 let androidVRNetwork = NetworkClient(context: InnerTubeContext(client: ClientConfig.androidVR, cookies: cookies, accessToken: nil))
                 if let fallback = try? await fetchAndDecipher(id: id, body: body, network: androidVRNetwork, visitor: nil, decipher: decipher) {
                     video = mergeStreams(into: video, from: fallback)
                 }
             }

             if decipher, video.streamingData?.hlsManifestUrl == nil {
                 let embeddedNetwork = NetworkClient(context: InnerTubeContext(client: ClientConfig.webEmbedded, cookies: cookies, accessToken: nil))
                 if let fallback = try? await fetchAndDecipher(id: id, body: body, network: embeddedNetwork, visitor: nil, decipher: decipher) {
                     video = mergeStreams(into: video, from: fallback)
                 }
             }

             let hasMuxedFormats = video.streamingData?.formats.contains(where: { $0.playbackUrl != nil }) == true
             if decipher, !hasMuxedFormats {
                 let androidNetwork = NetworkClient(context: InnerTubeContext(client: ClientConfig.android, cookies: cookies, accessToken: nil))
                 if let fallback = try? await fetchAndDecipher(id: id, body: body, network: androidNetwork, visitor: nil, decipher: decipher) {
                     video = mergeStreams(into: video, from: fallback)
                 }
             }

         } catch {
             releasePlayerSlot()
             throw error
         }
         releasePlayerSlot()
         return video
     }

     private func mergeStreams(into primary: YouTubeVideo, from fallback: YouTubeVideo) -> YouTubeVideo {
         guard fallback.streamingData != nil else { return primary }
         var merged = primary
         guard var fallbackSD = fallback.streamingData else { return primary }

         if var primarySD = merged.streamingData {
             if primarySD.hlsManifestUrl == nil {
                 primarySD.hlsManifestUrl = fallbackSD.hlsManifestUrl
             }
             if !primarySD.adaptiveFormats.contains(where: { $0.isAudioOnly && $0.playbackUrl != nil }) {
                 let audioStreams = fallbackSD.adaptiveFormats.filter { $0.isAudioOnly && $0.playbackUrl != nil }
                 primarySD.adaptiveFormats.append(contentsOf: audioStreams)
             }
             if !primarySD.formats.contains(where: { $0.playbackUrl != nil }) {
                 primarySD.formats = fallbackSD.formats.filter { $0.playbackUrl != nil }
             }
             merged.streamingData = primarySD
         } else {
             merged.streamingData = fallbackSD
         }
         return merged
     }

     private func printFallbackSummary(_ video: YouTubeVideo, label: String) {
         let audio  = video.streamingData?.adaptiveFormats.filter { $0.isAudioOnly && $0.playbackUrl != nil }.count ?? 0
         let muxed  = video.streamingData?.formats.filter { $0.playbackUrl != nil }.count ?? 0
         let hasHLS = video.streamingData?.hlsManifestUrl != nil
         print("DECIPHER ENGINE: \(label) merged — audio=\(audio) muxed=\(muxed) hls=\(hasHLS)")
     }

     private func hasPlayableStreams(_ video: YouTubeVideo) -> Bool {
         let hasHLS   = !(video.streamingData?.hlsManifestUrl?.isEmpty ?? true)
         let hasAudio = video.streamingData?.adaptiveFormats.contains(where: { $0.isAudioOnly && $0.playbackUrl != nil }) == true
         let hasMuxed = video.streamingData?.formats.contains(where: { $0.playbackUrl != nil }) == true
         return hasHLS || hasAudio || hasMuxed
     }

     private func fetchAndDecipher(id: String, body: [String: Any], network: NetworkClient, visitor: String?, decipher: Bool) async throws -> YouTubeVideo {
         let data = try await network.sendWithVisitorData("player", body: NetworkClient.SendableBody(body), visitorData: visitor)
         let decoder = JSONDecoder()
         var video = try decoder.decode(YouTubeVideo.self, from: data)

         if decipher, var streamingData = video.streamingData {
             var newAdaptive: [Stream] = []
             for var stream in streamingData.adaptiveFormats {
                 if stream.proxyUrl != nil {
                     newAdaptive.append(stream)
                 } else if let cipher = stream.signatureCipher {
                     if let decryptedURL = await Cipher.shared.decipher(url: stream.url ?? "", signatureCipher: cipher, network: network) {
                         stream.url = decryptedURL.absoluteString
                         stream.signatureCipher = nil
                         newAdaptive.append(stream)
                     }
                 } else if let url = stream.url {
                     if let decryptedURL = await Cipher.shared.decipherN(url: url, network: network) {
                         stream.url = decryptedURL.absoluteString
                     }
                     newAdaptive.append(stream)
                 }
             }
             streamingData.adaptiveFormats = newAdaptive

             var newFormats: [Stream] = []
             for var stream in streamingData.formats {
                 if stream.proxyUrl != nil {
                     newFormats.append(stream)
                 } else if let cipher = stream.signatureCipher {
                     if let decryptedURL = await Cipher.shared.decipher(url: stream.url ?? "", signatureCipher: cipher, network: network) {
                         stream.url = decryptedURL.absoluteString
                         stream.signatureCipher = nil
                         newFormats.append(stream)
                     }
                 } else if let url = stream.url {
                     if let decryptedURL = await Cipher.shared.decipherN(url: url, network: network) {
                         stream.url = decryptedURL.absoluteString
                     }
                     newFormats.append(stream)
                 }
             }
             streamingData.formats = newFormats
             video.streamingData = streamingData
         }
         return video
     }
     */

    /// Fetches search suggestions for Main YouTube using an external suggest endpoint.
    /// - Parameter query: The search term.
    /// - Returns: A list of suggested search terms.
    public func getSearchSuggestions(query: String, baseURL: String = YouTubeSDKConstants.URLS.API.youtubeSuggestionsURL) async throws -> [String] {
        guard let url = URL(string: baseURL) else { throw URLError(.badURL) }
        var components = URLComponents(url: url.appendingPathComponent("search"), resolvingAgainstBaseURL: true)
        components?.queryItems = [
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "client", value: "youtube"),
            URLQueryItem(name: "q", value: query),
        ]

        guard let url = components?.url else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)
        guard let responseString = String(data: data, encoding: .utf8) else { return [] }

        // The response is JSONP: window.google.ac.h(["query", [["suggestion", ...]]])
        guard let startBracket = responseString.firstIndex(of: "["),
              let endBracket = responseString.lastIndex(of: "]")
        else {
            return []
        }

        let jsonString = String(responseString[startBracket ... endBracket])
        guard let jsonArray = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [Any],
              jsonArray.count > 1,
              let suggestionsArray = jsonArray[1] as? [[Any]]
        else {
            return []
        }

        return suggestionsArray.compactMap { $0.first as? String }
    }

    /// Fetches an AI-powered summary of the video (if available).
    public func getVideoSummary(videoId: String) async throws -> YouTubeAISummary {
        let body: [String: String] = [
            "videoId": videoId,
            "engagementPanelType": "ENGAGEMENT_PANEL_TYPE_YOU_CHAT",
        ]
        let data = try await network.get("get_panel", body: body)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = YouTubeAISummary(from: json)
        else {
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
                baseURL: YouTubeSDKConstants.URLS.API.googleapisInnerTubeURL
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
                baseURL: YouTubeSDKConstants.URLS.API.googleapisInnerTubeURL
            )
            return try await fallback.get("browse", body: body)
        }
    }

    nonisolated func shouldKeepMusicHomeItem(_ item: YouTubeItem) -> Bool {
        switch item {
        case .song:
            true
        case let .playlist(playlist):
            isLikelyMusicMetadata(title: playlist.title, secondaryText: playlist.author)
        case let .video(video):
            isLikelyMusicMetadata(title: video.title, secondaryText: video.author)
        case let .channel(channel):
            isLikelyArtistChannelName(channel.title)
        case let .shelf(shelf):
            isLikelyMusicMetadata(title: shelf.title, secondaryText: nil)
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
            "orchestra",
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
            "interview",
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
            "topic",
        ]

        if positiveSignals.contains(where: { merged.contains($0) }) {
            return true
        }

        return isLikelyArtistChannelName(secondaryText ?? "")
    }
}

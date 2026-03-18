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
    
    /// Initializes the Client.
    /// - Parameter cookies: Optional "Cookie" header string. If provided, requests will be authenticated.
    public init(cookies: String? = nil) {
        let context = InnerTubeContext(client: ClientConfig.ios, cookies: cookies)
        let webContext = InnerTubeContext(client: ClientConfig.web, cookies: cookies)
        self.network = NetworkClient(context: context)
        self.webSearchNetwork = NetworkClient(context: webContext)
    }

    // MARK: - Browsing
    
    public func getHome() async throws -> YouTubeContinuation<YouTubeItem> {
        let data = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.home])
        return await parseContinuationResults(from: data)
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
        let diagnostics = diagnoseSearchResponse(from: data)
        print("yt_search_diagnostics client=WEB \(diagnostics.summary)")
        writeSearchDebugDump(data, clientName: "web")

        return parseContinuationResults(from: data)
    }

    public func writeSearchDebugDump(_ data: Data, clientName: String) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let tempFile = "yt_search_debug_\(clientName)_\(timestamp).json"
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tempFile)

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let debugData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted) else {
            return
        }

        try? debugData.write(to: tempURL, options: .atomic)
        print("yt_search_debug client=\(clientName) saved=\(tempURL.path)")
    }

    /// Fetches the full video details, including Streaming URLs (HLS).
    public func video(id: String) async throws -> YouTubeVideo {
        let data = try await network.get("player", body: ["videoId": id])
        let decoder = JSONDecoder()
        var video = try decoder.decode(YouTubeVideo.self, from: data)
        
        if video.requiresDeciphering {
            if var streamingData = video.streamingData {
                var newFormats: [Stream] = []
                for var stream in streamingData.adaptiveFormats {
                    if let cipher = stream.signatureCipher {
                        do {
                            let decryptedURL = try await Cipher.shared.decipher(url: stream.url ?? "", signatureCipher: cipher, network: network)
                            stream.url = decryptedURL.absoluteString
                            stream.signatureCipher = nil
                        } catch {
                            print("⚠️ Failed to decipher stream: \(error)")
                        }
                    }
                    newFormats.append(stream)
                }
                streamingData.adaptiveFormats = newFormats
                video.streamingData = streamingData
            }
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

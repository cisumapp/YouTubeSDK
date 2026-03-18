//
//  YouTubeClient+Parsing.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

struct SearchResponseDiagnostics: Sendable {
    let topLevelKeys: [String]
    let frameworkUpdateCount: Int
    let continuationItemCount: Int
    let directRendererCount: Int
    let wrapperRendererCount: Int

    var hasParseableContainers: Bool {
        // Only consider a response parseable if it contains direct renderers or continuations.
        // Many responses include EKO template "wrappers" which are not actual search result containers.
        return directRendererCount > 0 || continuationItemCount > 0
    }

    var summary: String {
        return "topLevelKeys=\(topLevelKeys) frameworkUpdates=\(frameworkUpdateCount) continuationItems=\(continuationItemCount) directRenderers=\(directRendererCount) wrappers=\(wrapperRendererCount) hasParseableContainers=\(hasParseableContainers)"
    }
}

extension YouTubeClient {

    // MARK: - Continuation

    /// Fetches the next page of results using a continuation token.
    /// - Parameter token: The token retrieved from a previous result.
    public func fetchContinuation(token: String) async throws -> YouTubeContinuation<YouTubeItem> {
        // Search continuations can be returned in different token encodings and
        // may require either the `search` or `browse` endpoint depending on
        // server-side routing. Try the most likely combinations in order.
        let tokenCandidates = continuationTokenCandidates(from: token)
        let endpointCandidates = ["search", "browse"]

        var attempt = 0
        var lastError: Error?
        for endpoint in endpointCandidates {
            for candidate in tokenCandidates {
                attempt += 1
                let body = ["continuation": candidate]
                do {
                    if attempt == 1 {
                        print("yt_fetch_continuation token_candidates=\(tokenCandidates.map { $0.count }) endpoints=\(endpointCandidates)")
                    }

                    print("yt_fetch_continuation try attempt=\(attempt) endpoint=\(endpoint) tokenLen=\(candidate.count) tokenHasPercent=\(candidate.contains("%"))")
                    let data = try await webSearchNetwork.get(endpoint, body: body)
                let diagnostics = diagnoseSearchResponse(from: data)
                    print("yt_fetch_continuation client=WEB attempt=\(attempt) endpoint=\(endpoint) \(diagnostics.summary)")
                    writeSearchDebugDump(data, clientName: "web_continuation_\(endpoint)")
                    return await parseContinuationResults(from: data)
                } catch {
                    lastError = error
                    let ns = error as NSError
                    print("yt_fetch_continuation error client=WEB attempt=\(attempt) endpoint=\(endpoint) code=\(ns.code) domain=\(ns.domain) body=\(body)")

                    // Lightweight backoff between candidate attempts.
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
            }
        }

        throw lastError ?? YouTubeError.apiError(message: "Unknown continuation failure")
    }

    private func continuationTokenCandidates(from token: String) -> [String] {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = [trimmed]
        var current = trimmed

        // Some responses ship continuation tokens in doubly/triply encoded forms.
        // Decode iteratively to produce a small candidate set.
        for _ in 0..<6 {
            guard let decoded = current.removingPercentEncoding, decoded != current else {
                break
            }
            current = decoded
            candidates.append(current)
        }

        // Preserve order while removing duplicates.
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    // MARK: - Helpers
    func findContinuationToken(in container: Any) -> String? {
        if let dict = container as? [String: Any] {
            if let token = dict["continuation"] as? String { return token }
            if let continuationData = (dict["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any] {
                return continuationData["token"] as? String
            }
            for value in dict.values {
                if let found = findContinuationToken(in: value) { return found }
            }
        } else if let array = container as? [Any] {
            for element in array {
                if let found = findContinuationToken(in: element) { return found }
            }
        }
        return nil
    }
    
    func findAll(key: String, in container: Any) -> [Any] {
        var results: [Any] = []
        if let dict = container as? [String: Any] {
            if let found = dict[key] { results.append(found) }
            for value in dict.values { results.append(contentsOf: findAll(key: key, in: value)) }
        } else if let array = container as? [Any] {
            for element in array { results.append(contentsOf: findAll(key: key, in: element)) }
        }
        return results
    }

    func diagnoseSearchResponse(from data: Data) -> SearchResponseDiagnostics {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return SearchResponseDiagnostics(
                topLevelKeys: [],
                frameworkUpdateCount: 0,
                continuationItemCount: 0,
                directRendererCount: 0,
                wrapperRendererCount: 0
            )
        }

        let keys = YouTubeSDKConstants.InternalKeys.Renderers.self
        let frameworkUpdates = (json["frameworkUpdates"] as? [String: Any])?["entityBatchUpdate"] as? [String: Any]
        let frameworkUpdateCount = (frameworkUpdates?["mutations"] as? [Any])?.count ?? 0

        let directRendererCount =
            findAll(key: keys.video, in: json).count +
            findAll(key: keys.gridVideo, in: json).count +
            findAll(key: keys.compactVideo, in: json).count +
            findAll(key: keys.videoWithContext, in: json).count +
            findAll(key: keys.channel, in: json).count +
            findAll(key: keys.playlist, in: json).count +
            findAll(key: keys.musicResponsiveListItem, in: json).count

        let wrapperRendererCount =
            findAll(key: keys.richItem, in: json).count +
            findAll(key: keys.itemSection, in: json).count +
            findAll(key: keys.shelf, in: json).count +
            findAll(key: "sectionListRenderer", in: json).count +
            findAll(key: "tabbedSearchResultsRenderer", in: json).count

        let continuationItemCount =
            findAll(key: "continuationItems", in: json).count +
            findAll(key: "appendContinuationItemsAction", in: json).count

        return SearchResponseDiagnostics(
            topLevelKeys: Array(json.keys).sorted(),
            frameworkUpdateCount: frameworkUpdateCount,
            continuationItemCount: continuationItemCount,
            directRendererCount: directRendererCount,
            wrapperRendererCount: wrapperRendererCount
        )
    }

    // MARK: - Generic Video Parser (For Channel/Playlist/Home)
    func parseVideos(from data: Data) -> [YouTubeVideo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        
        let keys = YouTubeSDKConstants.InternalKeys.Renderers.self
        let videos =
            findAll(key: keys.video, in: json) +
            findAll(key: keys.gridVideo, in: json) +
            findAll(key: keys.compactVideo, in: json) +
            findAll(key: keys.videoWithContext, in: json)
        
        return videos.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return YouTubeVideo(from: dict)
        }
    }
    
    func parseContinuationResults(from data: Data) -> YouTubeContinuation<YouTubeItem> {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return YouTubeContinuation(items: [], continuationToken: nil)
        }
        
        var results: [YouTubeItem] = []
        let keys = YouTubeSDKConstants.InternalKeys.Renderers.self
        var rawVideoNodes: [Any] = []
        rawVideoNodes.append(contentsOf: findAll(key: keys.video, in: json))
        rawVideoNodes.append(contentsOf: findAll(key: keys.gridVideo, in: json))
        rawVideoNodes.append(contentsOf: findAll(key: keys.compactVideo, in: json))
        rawVideoNodes.append(contentsOf: findAll(key: keys.videoWithContext, in: json))
        rawVideoNodes.append(contentsOf: findAll(key: keys.reelItem, in: json))
        rawVideoNodes.append(contentsOf: findAll(key: keys.richItem, in: json))
        rawVideoNodes.append(contentsOf: findAll(key: keys.itemSection, in: json))
        rawVideoNodes.append(contentsOf: findAll(key: keys.shelf, in: json))
        // Additional renderer/wrapper keys observed in some client responses
        rawVideoNodes.append(contentsOf: findAll(key: "videoCardRenderer", in: json))
        rawVideoNodes.append(contentsOf: findAll(key: "videoLockupRenderer", in: json))
        rawVideoNodes.append(contentsOf: findAll(key: "videoLockup", in: json))
        rawVideoNodes.append(contentsOf: findAll(key: "sectionListRenderer", in: json))
        rawVideoNodes.append(contentsOf: findAll(key: "tabbedSearchResultsRenderer", in: json))
        rawVideoNodes.append(contentsOf: findAll(key: "onResponseReceivedCommands", in: json))
        rawVideoNodes.append(contentsOf: findAll(key: "itemWrapperRenderer", in: json))
        // Attempt to parse any serialized template configs embedded in frameworkUpdates
        let serializedTemplates = findAll(key: "serializedTemplateConfig", in: json)
        for tpl in serializedTemplates {
            guard var tplStr = tpl as? String else { continue }
            // Percent-decode common URL-escaped payloads (many templates contain %3D etc.)
            if let decoded = tplStr.removingPercentEncoding { tplStr = decoded }

            // Try plain UTF8 JSON
            if let tplData = tplStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: tplData) {
                rawVideoNodes.append(contentsOf: findAll(key: keys.video, in: parsed))
                rawVideoNodes.append(contentsOf: findAll(key: "videoCardRenderer", in: parsed))
                rawVideoNodes.append(contentsOf: extractPotentialVideoPayloads(from: parsed))
                continue
            }

            // Try base64 -> JSON
            if let base64Data = Data(base64Encoded: tplStr),
               let parsed = try? JSONSerialization.jsonObject(with: base64Data) {
                rawVideoNodes.append(contentsOf: findAll(key: keys.video, in: parsed))
                rawVideoNodes.append(contentsOf: extractPotentialVideoPayloads(from: parsed))
                continue
            }

            // Some templates are double-encoded: try base64 after percent-decoding
            if let percentDecoded = tplStr.removingPercentEncoding,
               let base64Data2 = Data(base64Encoded: percentDecoded),
               let parsed2 = try? JSONSerialization.jsonObject(with: base64Data2) {
                rawVideoNodes.append(contentsOf: findAll(key: keys.video, in: parsed2))
                rawVideoNodes.append(contentsOf: extractPotentialVideoPayloads(from: parsed2))
            }
        }
        let videos = rawVideoNodes.flatMap { extractPotentialVideoPayloads(from: $0) }
        let channels = findAll(key: keys.channel, in: json)
        let playlists = findAll(key: keys.playlist, in: json)
        let songs = findAll(key: keys.musicResponsiveListItem, in: json)
        let shelves = findAll(key: keys.musicShelf, in: json)
        let carousels = findAll(key: keys.musicCarouselShelf, in: json)
        
        let counts: [String: Int] = [
            "video": videos.count,
            "channel": channels.count,
            "playlist": playlists.count,
            "song": songs.count,
            "musicShelf": shelves.count,
            "musicCarouselShelf": carousels.count
        ]
        
        print("parseContinuationResults counts \(counts)")
        
        var seenVideoIds = Set<String>()
        videos.forEach { dict in
            if let video = YouTubeVideo(from: dict),
               seenVideoIds.insert(video.id).inserted {
                results.append(.video(video))
            }
        }
        
        channels.forEach { item in
            if let dict = item as? [String: Any], let channel = YouTubeChannel(from: dict) {
                results.append(.channel(channel))
            }
        }
        
        playlists.forEach { item in
            if let dict = item as? [String: Any], let playlist = YouTubePlaylist(from: dict) {
                results.append(.playlist(playlist))
            }
        }
        
        songs.forEach { item in
            if let dict = item as? [String: Any], let song = YouTubeMusicSong(from: dict) {
                results.append(.song(song))
            }
        }
        
        (shelves + carousels).forEach { item in
            if let dict = item as? [String: Any], let title = (dict["title"] as? [String: Any])?["simpleText"] as? String {
                results.append(.shelf(YouTubeShelf(title: title, items: [])))
            }
        }
        
        let token = findContinuationToken(in: json)
        
        return YouTubeContinuation(items: results, continuationToken: token)
    }
}

// MARK: - Helper Methods

/// Extracts video-like payload dictionaries from nested wrappers such as
/// richItemRenderer/itemSectionRenderer/shelfRenderer/content arrays.
func extractPotentialVideoPayloads(from container: Any) -> [[String: Any]] {
    var out: [[String: Any]] = []
    
    if let dict = container as? [String: Any] {
        let keys = YouTubeSDKConstants.InternalKeys.Renderers.self
        let directKeys = [
            keys.video,
            keys.gridVideo,
            keys.compactVideo,
            keys.videoWithContext,
            keys.reelItem
        ]
        let extraDirect = [
            "videoCardRenderer",
            "videoLockupRenderer",
            "videoLockup",
            "video_model",
            "video_model_renderer"
        ]
        
        for key in directKeys {
            if let payload = dict[key] as? [String: Any] {
                out.append(payload)
            }
        }
        for key in extraDirect {
            if let payload = dict[key] as? [String: Any] {
                out.append(payload)
            }
        }
        
        // If this dictionary itself is already a video-like payload.
        if dict["videoId"] as? String != nil {
            out.append(dict)
        }
        
        if let content = dict["content"] {
            out.append(contentsOf: extractPotentialVideoPayloads(from: content))
        }
        if let contents = dict["contents"] {
            out.append(contentsOf: extractPotentialVideoPayloads(from: contents))
        }
        if let items = dict["items"] {
            out.append(contentsOf: extractPotentialVideoPayloads(from: items))
        }
    } else if let array = container as? [Any] {
        for element in array {
            out.append(contentsOf: extractPotentialVideoPayloads(from: element))
        }
    }
    
    return out
}

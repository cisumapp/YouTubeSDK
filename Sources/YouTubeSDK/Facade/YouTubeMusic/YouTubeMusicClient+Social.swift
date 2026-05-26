//
//  YouTubeMusicClient+Social.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

extension YouTubeMusicClient {
    
    public func getLyrics(videoId: String) async throws -> String? {
        let nextData = try await network.get("next", body: ["videoId": videoId])
        guard let json = try? JSONSerialization.jsonObject(with: nextData) as? [String: Any] else { return nil }
        
        let tabs = findAll(key: "tabRenderer", in: json)
        guard let lyricsTab = tabs.first(where: { ($0 as? [String: Any])?["title"] as? String == "Lyrics" }) as? [String: Any],
              let endpoint = lyricsTab["endpoint"] as? [String: Any],
              let browseId = (endpoint["browseEndpoint"] as? [String: Any])?["browseId"] as? String else {
            return nil
        }
        
        let lyricsData = try await network.get("browse", body: ["browseId": browseId])
        guard let lyricsJson = try? JSONSerialization.jsonObject(with: lyricsData) as? [String: Any] else { return nil }
        
        let descriptions = findAll(key: "musicDescriptionShelfRenderer", in: lyricsJson)
        if let shelf = descriptions.first as? [String: Any],
           let desc = shelf["description"] as? [String: Any],
           let runs = desc["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }
    
    // MARK: - Interactions
    
    public func like(videoId: String) async throws {
        let body: [String: Any] = ["target": ["videoId": videoId]]
        _ = try await network.sendComplexRequest("like/like", body: body)
    }
    
    public func removeLike(videoId: String) async throws {
        let body: [String: Any] = ["target": ["videoId": videoId]]
        _ = try await network.sendComplexRequest("like/removelike", body: body)
    }
    
    public func dislike(videoId: String) async throws {
        let body: [String: Any] = ["target": ["videoId": videoId]]
        _ = try await network.sendComplexRequest("like/dislike", body: body)
    }
    
    public func subscribe(channelId: String) async throws {
        let body: [String: Any] = ["channelIds": [channelId]]
        _ = try await network.sendComplexRequest("subscription/subscribe", body: body)
    }
    
    public func unsubscribe(channelId: String) async throws {
        let body: [String: Any] = ["channelIds": [channelId]]
        _ = try await network.sendComplexRequest("subscription/unsubscribe", body: body)
    }
}

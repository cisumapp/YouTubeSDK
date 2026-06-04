//
//  YouTubeClient+Social.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

public extension YouTubeClient {
    // MARK: - Interactions

    /// Likes a video.
    func like(videoId: String) async throws {
        let body: [String: Any] = [
            "target": ["videoId": videoId],
        ]
        _ = try await network.sendComplexRequest("like/like", body: body)
    }

    /// Removes a like from a video.
    func removeLike(videoId: String) async throws {
        let body: [String: Any] = [
            "target": ["videoId": videoId],
        ]
        _ = try await network.sendComplexRequest("like/removelike", body: body)
    }

    /// Dislikes a video.
    func dislike(videoId: String) async throws {
        let body: [String: Any] = [
            "target": ["videoId": videoId],
        ]
        _ = try await network.sendComplexRequest("like/dislike", body: body)
    }

    /// Subscribes to a channel.
    func subscribe(channelId: String) async throws {
        let body: [String: Any] = [
            "channelIds": [channelId],
        ]
        _ = try await network.sendComplexRequest("subscription/subscribe", body: body)
    }

    /// Unsubscribes from a channel.
    func unsubscribe(channelId: String) async throws {
        let body: [String: Any] = [
            "channelIds": [channelId],
        ]
        _ = try await network.sendComplexRequest("subscription/unsubscribe", body: body)
    }

    /// Fetches the "Guide" data, which contains the user's sidebar, library categories, and subs.
    func getGuide() async throws -> [String: Any] {
        let data = try await network.sendComplexRequest("guide", body: [:])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeError.parsingError(details: "Could not parse Guide response")
        }
        return json
    }
}

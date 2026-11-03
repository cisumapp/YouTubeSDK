//
//  YouTubeMusicClient+Details.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

public extension YouTubeMusicClient {
    /// Fetches full Artist details (Songs, Albums, Singles)
    func getArtist(browseId: String) async throws -> YouTubeMusicArtistDetail {
        let body = ["browseId": browseId]
        let data = try await network.get("browse", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let header = (json["header"] as? [String: Any])?["musicImmersiveHeaderRenderer"] as? [String: Any]
            ?? (json["header"] as? [String: Any])?["musicVisualHeaderRenderer"] as? [String: Any]
        func text(_ key: String) -> String? {
            let runs = (header?[key] as? [String: Any])?["runs"] as? [[String: Any]]
            return runs.map { $0.compactMap { $0["text"] as? String }.joined() }
        }
        let thumbnails = (((header?["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        return YouTubeMusicArtistDetail(
            id: browseId,
            name: text("title"),
            about: text("description"),
            photoURL: (thumbnails?.last?["url"] as? String).flatMap(URL.init(string:)),
            audience: text("monthlyListenerCount"),
            sections: parseSections(from: json)
        )
    }

    /// Fetches Album details (Tracks)
    func getAlbum(browseId: String) async throws -> [YouTubeMusicSong] {
        let body = ["browseId": browseId]
        let data = try await network.get("browse", body: body)
        return parseMusicItems(from: data)
    }

    /// Fetches Playlist details (Tracks)
    func getPlaylist(browseId: String) async throws -> [YouTubeMusicSong] {
        let browseId = browseId.hasPrefix("PL") ? "VL\(browseId)" : browseId
        let body = ["browseId": browseId]
        let data = try await network.get("browse", body: body)
        return parseMusicItems(from: data)
    }
}

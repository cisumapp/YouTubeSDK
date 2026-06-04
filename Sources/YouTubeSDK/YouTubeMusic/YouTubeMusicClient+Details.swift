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
        let sections = await parseSections(from: json)
        return YouTubeMusicArtistDetail(id: browseId, sections: sections)
    }

    /// Fetches Album details (Tracks)
    func getAlbum(browseId: String) async throws -> [YouTubeMusicSong] {
        let body = ["browseId": browseId]
        let data = try await network.get("browse", body: body)
        return await parseMusicItems(from: data)
    }

    /// Fetches Playlist details (Tracks)
    func getPlaylist(browseId: String) async throws -> [YouTubeMusicSong] {
        let browseId = browseId.hasPrefix("PL") ? "VL\(browseId)" : browseId
        let body = ["browseId": browseId]
        let data = try await network.get("browse", body: body)
        return await parseMusicItems(from: data)
    }
}

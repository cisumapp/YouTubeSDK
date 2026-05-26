//
//  YouTubeClient+Playlists.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

extension YouTubeClient {
    
    /// Creates a new playlist.
    /// - Parameters:
    ///   - title: The title of the playlist.
    ///   - description: Optional description.
    ///   - privacy: Privacy status ("PUBLIC", "UNLISTED", or "PRIVATE").
    public func createPlaylist(title: String, description: String? = nil, privacy: String = "PRIVATE") async throws -> String {
        var body: [String: Any] = [
            "title": title,
            "privacyStatus": privacy
        ]
        if let description = description {
            body["description"] = description
        }
        
        let data = try await network.sendComplexRequest("playlist/create", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playlistId = json["playlistId"] as? String else {
            throw YouTubeError.apiError(message: "Failed to create playlist or extract ID")
        }
        return playlistId
    }
    
    /// Deletes a playlist by its ID.
    public func deletePlaylist(id: String) async throws {
        let body = ["playlistId": id]
        let _ = try await network.sendComplexRequest("playlist/delete", body: body)
    }
    
    /// Adds a video to a specific playlist.
    public func addVideoToPlaylist(videoId: String, playlistId: String) async throws {
        let body: [String: Any] = [
            "playlistId": playlistId,
            "actions": [
                ["action": "ACTION_ADD_VIDEO", "addedVideoId": videoId]
            ]
        ]
        let _ = try await network.sendComplexRequest("browse/edit_playlist", body: body)
    }
    
    /// Removes a video from a specific playlist.
    public func removeVideoFromPlaylist(videoId: String, playlistId: String) async throws {
        // First we need to find the setVideoId (the unique ID of the video WITHIN the playlist)
        // This is simplified; usually we'd need the setVideoId from the playlist items results
        let body: [String: Any] = [
            "playlistId": playlistId,
            "actions": [
                ["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": videoId]
            ]
        ]
        let _ = try await network.sendComplexRequest("browse/edit_playlist", body: body)
    }
}

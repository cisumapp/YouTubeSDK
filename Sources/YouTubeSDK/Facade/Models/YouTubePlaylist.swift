//
//  YouTubePlaylist.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//


import Foundation

public struct YouTubePlaylist: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let thumbnailURL: URL?
    public let videoCount: String?
    public let author: String?
    
    init?(from data: [String: Any]) {
        guard let id = data["playlistId"] as? String else { return nil }
        self.id = id
        
        if let title = data["title"] as? [String: Any],
           let simple = title["simpleText"] as? String {
            self.title = simple
        } else {
            self.title = "Unknown Playlist"
        }
        
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let url = thumbnails.last?["url"] as? String {
            self.thumbnailURL = URL(string: url)
        } else {
            self.thumbnailURL = nil
        }
        
        self.videoCount = (data["videoCount"] as? String) ?? (data["videoCountText"] as? [String: Any])?["simpleText"] as? String
        
        if let owner = data["ownerText"] as? [String: Any],
           let runs = owner["runs"] as? [[String: Any]],
           let name = runs.first?["text"] as? String {
            self.author = name
        } else {
            self.author = nil
        }
    }
}
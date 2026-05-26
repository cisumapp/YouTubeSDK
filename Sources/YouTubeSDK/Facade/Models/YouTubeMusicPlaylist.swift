    //
//  YouTubeMusicPlaylist.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//


import Foundation

public struct YouTubeMusicPlaylist: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let author: String?
    public let count: String?
    public let thumbnailURL: URL?
    
    init?(from data: [String: Any]) {
        guard let id = data["browseId"] as? String ?? data["playlistId"] as? String else { return nil }
        self.id = id
        self.title = data["title"] as? String ?? "Unknown Playlist"
        self.count = data["itemCount"] as? String
        
        if let authors = data["authors"] as? [[String: Any]], let first = authors.first {
            self.author = first["name"] as? String
        } else {
            self.author = nil
        }
        
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let urlString = thumbnails.last?["url"] as? String {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }
    }
}

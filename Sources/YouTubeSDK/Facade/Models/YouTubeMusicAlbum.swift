//
//  YouTubeMusicAlbum.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//


import Foundation

public struct YouTubeMusicAlbum: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artist: String?
    public let year: String?
    public let thumbnailURL: URL?
    public let explicit: Bool
    
    init?(from data: [String: Any]) {
        guard let id = data["browseId"] as? String ?? data["playlistId"] as? String else { return nil }
        self.id = id
        self.title = data["title"] as? String ?? "Unknown Album"
        self.year = data["year"] as? String
        self.explicit = (data["isExplicit"] as? Bool) ?? false
        
        // Artist might be a string or nested object depending on endpoint
        if let artists = data["artists"] as? [[String: Any]], let first = artists.first {
            self.artist = first["name"] as? String
        } else {
            self.artist = nil
        }
        
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let urlString = thumbnails.last?["url"] as? String {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }
    }
}
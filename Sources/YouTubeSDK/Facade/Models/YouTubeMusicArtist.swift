//
//  YouTubeMusicArtist.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//


import Foundation

public struct YouTubeMusicArtist: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let thumbnailURL: URL?
    public let subscriberCount: String?
    
    init?(from data: [String: Any]) {
        // Handle both "browseId" (from search) and "id" (from inline)
        guard let id = data["browseId"] as? String ?? data["id"] as? String else { return nil }
        self.id = id
        self.name = data["name"] as? String ?? "Unknown Artist"
        
        if let thumbnails = data["thumbnails"] as? [[String: Any]],
           let urlString = thumbnails.last?["url"] as? String {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }
        
        self.subscriberCount = data["subscriberCount"] as? String
    }
}
//
//  YouTubeChannel.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//


import Foundation

public struct YouTubeChannel: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let thumbnailURL: URL?
    public let subscriberCount: String?
    public let videoCount: String?
    
    init?(from data: [String: Any]) {
        // Handle Search Result & Browse Header
        guard let id = data["channelId"] as? String ?? data["browseId"] as? String else { return nil }
        self.id = id
        
        // Title
        if let title = data["title"] as? [String: Any],
           let simple = title["simpleText"] as? String {
            self.title = simple
        } else if let title = data["title"] as? [String: Any],
                  let runs = title["runs"] as? [[String: Any]],
                  let text = runs.first?["text"] as? String {
            self.title = text
        } else {
            self.title = (data["title"] as? String) ?? "Unknown Channel"
        }
        
        // Thumbnail
        if let thumbs = (data["thumbnail"] ?? data["avatar"]) as? [String: Any],
           let list = thumbs["thumbnails"] as? [[String: Any]],
           let url = list.last?["url"] as? String {
            self.thumbnailURL = URL(string: url)
        } else {
            self.thumbnailURL = nil
        }
        
        // Metadata
        self.subscriberCount = (data["subscriberCountText"] as? [String: Any])?["simpleText"] as? String
        self.videoCount = (data["videoCountText"] as? [String: Any])?["simpleText"] as? String
    }
}
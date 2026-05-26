//
//  YouTubeItem.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

public enum YouTubeItem: Sendable {
    case video(YouTubeVideo)
    case song(YouTubeMusicSong)
    case playlist(YouTubePlaylist)
    case channel(YouTubeChannel)
    case shelf(YouTubeShelf)
}

public struct YouTubeShelf: Sendable {
    public let title: String
    public let items: [YouTubeItem]
    
    public init(title: String, items: [YouTubeItem]) {
        self.title = title
        self.items = items
    }
}

//
//  YouTubeItem.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

public enum YouTubeItem: Sendable, Codable {
    case video(YouTubeVideo)
    case song(YouTubeMusicSong)
    case playlist(YouTubePlaylist)
    case channel(YouTubeChannel)
    case shelf(YouTubeShelf)

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum ItemType: String, Codable {
        case video, song, playlist, channel, shelf
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .video(video):
            try container.encode(ItemType.video, forKey: .type)
            try container.encode(video, forKey: .payload)
        case let .song(song):
            try container.encode(ItemType.song, forKey: .type)
            try container.encode(song, forKey: .payload)
        case let .playlist(playlist):
            try container.encode(ItemType.playlist, forKey: .type)
            try container.encode(playlist, forKey: .payload)
        case let .channel(channel):
            try container.encode(ItemType.channel, forKey: .type)
            try container.encode(channel, forKey: .payload)
        case let .shelf(shelf):
            try container.encode(ItemType.shelf, forKey: .type)
            try container.encode(shelf, forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ItemType.self, forKey: .type)
        switch type {
        case .video:
            self = .video(try container.decode(YouTubeVideo.self, forKey: .payload))
        case .song:
            self = .song(try container.decode(YouTubeMusicSong.self, forKey: .payload))
        case .playlist:
            self = .playlist(try container.decode(YouTubePlaylist.self, forKey: .payload))
        case .channel:
            self = .channel(try container.decode(YouTubeChannel.self, forKey: .payload))
        case .shelf:
            self = .shelf(try container.decode(YouTubeShelf.self, forKey: .payload))
        }
    }
}

public struct YouTubeShelf: Sendable, Codable {
    public let title: String
    public let items: [YouTubeItem]

    public init(title: String, items: [YouTubeItem]) {
        self.title = title
        self.items = items
    }
}

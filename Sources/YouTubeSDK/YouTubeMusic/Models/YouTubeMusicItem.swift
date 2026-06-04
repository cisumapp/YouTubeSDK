//
//  YouTubeMusicItem.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//

import Foundation

public enum YouTubeMusicItem: Identifiable, Sendable {
    case song(YouTubeMusicSong)
    case album(YouTubeMusicAlbum)
    case artist(YouTubeMusicArtist)
    case playlist(YouTubeMusicPlaylist)

    public var id: String {
        switch self {
        case let .song(s): s.id
        case let .album(a): a.id
        case let .artist(a): a.id
        case let .playlist(p): p.id
        }
    }
}

public struct YouTubeMusicArtistDetail: Identifiable, Sendable {
    public let id: String
    public let sections: [YouTubeMusicSection]
}

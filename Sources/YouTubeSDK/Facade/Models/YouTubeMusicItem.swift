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
        case .song(let s): return s.id
        case .album(let a): return a.id
        case .artist(let a): return a.id
        case .playlist(let p): return p.id
        }
    }
}

public struct YouTubeMusicArtistDetail: Identifiable, Sendable {
    public let id: String
    public let sections: [YouTubeMusicSection]
}

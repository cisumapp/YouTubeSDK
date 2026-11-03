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
    /// From the page header; `nil` when YouTube sends a header shape this does not know.
    public let name: String?
    public let about: String?
    /// The wide banner photo, up to 2880px.
    public let photoURL: URL?
    /// "204M monthly audience".
    public let audience: String?
    /// In page order: "Top songs", "Albums", "Singles & EPs", "Videos", "Live performances",
    /// "Featured on", "Playlists by …", "Fans might also like".
    public let sections: [YouTubeMusicSection]
}

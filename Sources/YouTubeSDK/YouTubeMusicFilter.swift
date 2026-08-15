//
//  YouTubeMusicFilter.swift
//  YouTubeSDK
//
//  Heuristics about YouTube's own data: which search rows and home-feed entries are music rather
//  than podcasts, trailers, or interviews.
//
//  They take YouTubeSDK types, so they belong beside those types rather than in generic Utilities.
//  The string-only helpers they call — isLikelyMusicMetadata, isLikelyArtistChannelName — stay in
//  Utilities, since those work on plain strings and have no provider knowledge.
//
//  Home and Search are both consumers, and this package is the one thing they already share.
//

import Foundation
import Utilities

public nonisolated func shouldKeepMusicHomeItem(_ item: YouTubeItem) -> Bool {
    switch item {
    case .song:
        true
    case let .video(video):
        shouldKeepMusicVideoResult(video)
    case let .channel(channel):
        shouldKeepMusicChannel(channel)
    case let .playlist(playlist):
        shouldKeepMusicPlaylist(playlist)
    case let .shelf(shelf):
        isLikelyMusicMetadata(title: shelf.title, secondaryText: nil)
    }
}

public nonisolated func shouldKeepMusicVideoResult(_ video: YouTubeVideo) -> Bool {
    isLikelyMusicMetadata(title: video.title, secondaryText: video.author)
}

public nonisolated func shouldKeepMusicChannel(_ channel: YouTubeChannel) -> Bool {
    isLikelyArtistChannelName(channel.title)
}

public nonisolated func shouldKeepMusicPlaylist(_ playlist: YouTubePlaylist) -> Bool {
    isLikelyMusicMetadata(title: playlist.title, secondaryText: playlist.author)
}

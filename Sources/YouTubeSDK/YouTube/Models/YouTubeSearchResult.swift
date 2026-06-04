//
//  YouTubeSearchResult.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//

import Foundation

public enum YouTubeSearchResult: Identifiable, Sendable {
    case video(YouTubeVideo)
    case channel(YouTubeChannel)
    case playlist(YouTubePlaylist)

    public var id: String {
        switch self {
        case let .video(v): v.id
        case let .channel(c): c.id
        case let .playlist(p): p.id
        }
    }
}

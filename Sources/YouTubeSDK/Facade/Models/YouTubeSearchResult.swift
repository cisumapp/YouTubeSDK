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
        case .video(let v): return v.id
        case .channel(let c): return c.id
        case .playlist(let p): return p.id
        }
    }
}
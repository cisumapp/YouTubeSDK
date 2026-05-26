//
//  YouTubeMusicRadioQueue.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 11/04/26.
//

import Foundation

public struct YouTubeMusicRadioQueue: Sendable {
    public let items: [YouTubeMusicSong]
    public let continuationToken: String?
    public let playlistId: String?

    public init(items: [YouTubeMusicSong], continuationToken: String?, playlistId: String?) {
        self.items = items
        self.continuationToken = continuationToken
        self.playlistId = playlistId
    }
}
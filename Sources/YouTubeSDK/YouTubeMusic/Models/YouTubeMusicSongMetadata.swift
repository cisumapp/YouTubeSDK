//
//  YouTubeMusicSongMetadata.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 11/04/26.
//

import Foundation

public struct YouTubeMusicFeedbackTokens: Sendable {
    public let primary: String?
    public let undo: String?
    public let all: [String]

    public init(primary: String?, undo: String?, all: [String]) {
        self.primary = primary
        self.undo = undo
        self.all = all
    }
}

public struct YouTubeMusicSongMetadata: Sendable {
    public let song: YouTubeMusicSong?
    public let videoId: String
    public let playlistId: String?
    public let continuationToken: String?
    public let feedbackTokens: YouTubeMusicFeedbackTokens

    public init(
        song: YouTubeMusicSong?,
        videoId: String,
        playlistId: String?,
        continuationToken: String?,
        feedbackTokens: YouTubeMusicFeedbackTokens
    ) {
        self.song = song
        self.videoId = videoId
        self.playlistId = playlistId
        self.continuationToken = continuationToken
        self.feedbackTokens = feedbackTokens
    }
}
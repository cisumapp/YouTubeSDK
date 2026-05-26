//
//  YouTubeMusicLibrary.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 11/04/26.
//

import Foundation

public struct YouTubeMusicLibraryFilterChip: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let browseId: String
    public let params: String?

    public init(title: String, browseId: String, params: String?) {
        self.title = title
        self.browseId = browseId
        self.params = params
        if let params, !params.isEmpty {
            self.id = "\(browseId)|\(params)"
        } else {
            self.id = browseId
        }
    }
}

public struct YouTubeMusicLibraryLanding: Sendable {
    public let sections: [YouTubeMusicSection]
    public let filterChips: [YouTubeMusicLibraryFilterChip]
    public let continuationToken: String?

    public init(
        sections: [YouTubeMusicSection],
        filterChips: [YouTubeMusicLibraryFilterChip],
        continuationToken: String?
    ) {
        self.sections = sections
        self.filterChips = filterChips
        self.continuationToken = continuationToken
    }
}
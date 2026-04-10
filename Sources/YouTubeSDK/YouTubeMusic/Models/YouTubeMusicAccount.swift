//
//  YouTubeMusicAccount.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 11/04/26.
//

import Foundation

public struct YouTubeMusicBrandAccount: Identifiable, Sendable {
    public let id: String
    public let pageId: String
    public let name: String
    public let handle: String?
    public let isSelected: Bool

    public init(pageId: String, name: String, handle: String?, isSelected: Bool) {
        self.pageId = pageId
        self.id = pageId
        self.name = name
        self.handle = handle
        self.isSelected = isSelected
    }
}

public struct YouTubeMusicAccountsList: Sendable {
    public let primaryEmail: String?
    public let accounts: [YouTubeMusicBrandAccount]

    public init(primaryEmail: String?, accounts: [YouTubeMusicBrandAccount]) {
        self.primaryEmail = primaryEmail
        self.accounts = accounts
    }
}
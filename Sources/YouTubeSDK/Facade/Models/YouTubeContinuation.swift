//
//  YouTubeContinuation.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

public struct YouTubeContinuation<T: Sendable>: Sendable {
    public let items: [T]
    public let continuationToken: String?
    
    public init(items: [T], continuationToken: String?) {
        self.items = items
        self.continuationToken = continuationToken
    }
}

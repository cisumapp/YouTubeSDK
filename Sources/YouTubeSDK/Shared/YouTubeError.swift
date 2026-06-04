//
//  YouTubeError.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

public enum YouTubeError: LocalizedError {
    case networkError(Error)
    case apiError(message: String)
    case parsingError(details: String)
    case decipheringFailed(videoId: String)
    case authenticationRequired
    case unknown

    public var errorDescription: String? {
        switch self {
        case let .networkError(error):
            "Network Error: \(error.localizedDescription)"
        case let .apiError(message):
            "API Error: \(message)"
        case let .parsingError(details):
            "Parsing Error: \(details)"
        case let .decipheringFailed(videoId):
            "Deciphering Failed for video ID: \(videoId)"
        case .authenticationRequired:
            "Authentication Required: Please sign in to perform this action."
        case .unknown:
            "An unknown error occurred."
        }
    }
}

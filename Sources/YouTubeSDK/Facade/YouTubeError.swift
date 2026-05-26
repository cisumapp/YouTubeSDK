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
        case .networkError(let error):
            return "Network Error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API Error: \(message)"
        case .parsingError(let details):
            return "Parsing Error: \(details)"
        case .decipheringFailed(let videoId):
            return "Deciphering Failed for video ID: \(videoId)"
        case .authenticationRequired:
            return "Authentication Required: Please sign in to perform this action."
        case .unknown:
            return "An unknown error occurred."
        }
    }
}

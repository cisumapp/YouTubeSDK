//
//  Stream.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 30/12/25.
//

import Foundation

public struct Stream: Decodable, Sendable {
    public var url: String? // Direct URL (if available)
    public let itag: Int
    public let mimeType: String
    public let bitrate: Int
    public let width: Int?
    public let height: Int?
    public let contentLength: String?
    public let qualityLabel: String? // e.g., "1080p", "720p"
    public let audioQuality: String? // e.g., "AUDIO_QUALITY_MEDIUM"
    public let approxDurationMs: String?
    public var signatureCipher: String? // Encrypted signature
    
    // Helpers
    public var isAudioOnly: Bool {
        return mimeType.starts(with: "audio")
    }
    
    public var isVideoOnly: Bool {
        return mimeType.starts(with: "video") && (audioQuality == nil)
    }
}

public struct StreamingData: Decodable, Sendable {
    public let expiresInSeconds: String?
    public var formats: [Stream]         // Muxed (Video + Audio)
    public var adaptiveFormats: [Stream] // Separate tracks
    public let hlsManifestUrl: String?   // The golden ticket for iOS AVPlayer
    
    enum CodingKeys: String, CodingKey {
        case expiresInSeconds
        case formats
        case adaptiveFormats
        case hlsManifestUrl
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // decodeIfPresent returns nil if key is missing.
        // We use '?? []' to default to an empty list so your code doesn't crash.
        self.formats = try container.decodeIfPresent([Stream].self, forKey: .formats) ?? []
        self.adaptiveFormats = try container.decodeIfPresent([Stream].self, forKey: .adaptiveFormats) ?? []
        
        self.expiresInSeconds = try container.decodeIfPresent(String.self, forKey: .expiresInSeconds)
        self.hlsManifestUrl = try container.decodeIfPresent(String.self, forKey: .hlsManifestUrl)
    }
}

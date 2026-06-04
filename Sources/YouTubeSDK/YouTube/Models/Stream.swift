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
    public var proxyUrl: String? // YouTube's proxy delivery URL (new as of 2025)

    enum CodingKeys: String, CodingKey {
        case url
        case itag
        case mimeType
        case bitrate
        case width
        case height
        case contentLength
        case qualityLabel
        case audioQuality
        case approxDurationMs
        case signatureCipher
        case proxyUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try c.decodeIfPresent(String.self, forKey: .url)
        self.itag = try c.decode(Int.self, forKey: .itag)
        self.mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        self.bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate) ?? 0
        self.width = try c.decodeIfPresent(Int.self, forKey: .width)
        self.height = try c.decodeIfPresent(Int.self, forKey: .height)
        self.contentLength = try c.decodeIfPresent(String.self, forKey: .contentLength)
        self.qualityLabel = try c.decodeIfPresent(String.self, forKey: .qualityLabel)
        self.audioQuality = try c.decodeIfPresent(String.self, forKey: .audioQuality)
        self.approxDurationMs = try c.decodeIfPresent(String.self, forKey: .approxDurationMs)
        self.signatureCipher = try c.decodeIfPresent(String.self, forKey: .signatureCipher)
        self.proxyUrl = try c.decodeIfPresent(String.self, forKey: .proxyUrl)
    }

    // MARK: - Helpers

    public var isAudioOnly: Bool {
        mimeType.starts(with: "audio")
    }

    public var isVideoOnly: Bool {
        mimeType.starts(with: "video") && (audioQuality == nil)
    }

    /// The best URL to use for playback — prefers the direct (deciphered) URL, falls back to proxyUrl.
    public var playbackUrl: String? {
        url ?? proxyUrl
    }
}

public struct StreamingData: Decodable, Sendable {
    public let expiresInSeconds: String?
    public var formats: [Stream] // Muxed (Video + Audio)
    public var adaptiveFormats: [Stream] // Separate tracks
    public var hlsManifestUrl: String? // The golden ticket for iOS AVPlayer

    enum CodingKeys: String, CodingKey {
        case expiresInSeconds
        case formats
        case adaptiveFormats
        case hlsManifestUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.formats = try container.decodeIfPresent([Stream].self, forKey: .formats) ?? []
        self.adaptiveFormats = try container.decodeIfPresent([Stream].self, forKey: .adaptiveFormats) ?? []
        self.expiresInSeconds = try container.decodeIfPresent(String.self, forKey: .expiresInSeconds)
        self.hlsManifestUrl = try container.decodeIfPresent(String.self, forKey: .hlsManifestUrl)
    }
}

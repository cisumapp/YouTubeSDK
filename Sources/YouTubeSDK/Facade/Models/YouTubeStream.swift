import Foundation

public struct YouTubeStream: Decodable, Sendable {
    public var url: String?          // Direct URL (if available)
    public let itag: Int
    public let mimeType: String
    public let bitrate: Int
    public let width: Int?
    public let height: Int?
    public let contentLength: String?
    public let qualityLabel: String?  // e.g., "1080p", "720p"
    public let audioQuality: String?  // e.g., "AUDIO_QUALITY_MEDIUM"
    public let approxDurationMs: String?
    public var signatureCipher: String?  // Encrypted signature
    public var proxyUrl: String?         // YouTube's proxy delivery URL (new as of 2025)

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

    public init(url: String?, itag: Int, mimeType: String, bitrate: Int, width: Int?, height: Int?, contentLength: String?, qualityLabel: String?, audioQuality: String?, approxDurationMs: String?, signatureCipher: String?, proxyUrl: String?) {
        self.url = url
        self.itag = itag
        self.mimeType = mimeType
        self.bitrate = bitrate
        self.width = width
        self.height = height
        self.contentLength = contentLength
        self.qualityLabel = qualityLabel
        self.audioQuality = audioQuality
        self.approxDurationMs = approxDurationMs
        self.signatureCipher = signatureCipher
        self.proxyUrl = proxyUrl
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url              = try c.decodeIfPresent(String.self, forKey: .url)
        itag             = try c.decode(Int.self,             forKey: .itag)
        mimeType         = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        bitrate          = try c.decodeIfPresent(Int.self,    forKey: .bitrate)  ?? 0
        width            = try c.decodeIfPresent(Int.self,    forKey: .width)
        height           = try c.decodeIfPresent(Int.self,    forKey: .height)
        contentLength    = try c.decodeIfPresent(String.self, forKey: .contentLength)
        qualityLabel     = try c.decodeIfPresent(String.self, forKey: .qualityLabel)
        audioQuality     = try c.decodeIfPresent(String.self, forKey: .audioQuality)
        approxDurationMs = try c.decodeIfPresent(String.self, forKey: .approxDurationMs)
        signatureCipher  = try c.decodeIfPresent(String.self, forKey: .signatureCipher)
        proxyUrl         = try c.decodeIfPresent(String.self, forKey: .proxyUrl)
    }

    // MARK: - Helpers

    public var isAudioOnly: Bool {
        return mimeType.starts(with: "audio")
    }

    public var isVideoOnly: Bool {
        return mimeType.starts(with: "video") && (audioQuality == nil)
    }

    /// The best URL to use for playback — prefers the direct (deciphered) URL, falls back to proxyUrl.
    public var playbackUrl: String? {
        return url ?? proxyUrl
    }

    /// HTTP headers required for successful playback of this specific stream.
    /// Includes User-Agent and potentially Origin/Referer depending on the stream source.
    public var playbackHeaders: [String: String] {
        guard let pURL = playbackUrl, let urlObj = URL(string: pURL) else { return [:] }
        let host = urlObj.host ?? ""
        
        // HLS manifests (manifest.googlevideo.com) or those containing c=WEB*
        // typically require Web headers.
        let isWebStream = host.contains("manifest.googlevideo.com") || pURL.contains("c=WEB")
        
        var headers: [String: String] = [
            "User-Agent": isWebStream ? InnerTubeClients.Web.userAgent : InnerTubeClients.iOS.userAgent
        ]
        
        if isWebStream {
            headers["Origin"] = "https://www.youtube.com"
            headers["Referer"] = "https://www.youtube.com/"
        }
        
        return headers
    }
}

public struct YouTubeStreamingData: Decodable, Sendable {
    public let expiresInSeconds: String?
    public var formats: [YouTubeStream]          // Muxed (Video + Audio)
    public var adaptiveFormats: [YouTubeStream]  // Separate tracks
    public var hlsManifestUrl: String?    // The golden ticket for iOS AVPlayer

    /// Mapping of unsolved to solved n-parameters (throttle tokens).
    /// Used by YTHLSProxyLoader to rewrite the M3U8 playlist.
    public var nSolver: (unsolved: String, solved: String)?

    /// HTTP headers required for HLS playback.
    public var hlsPlaybackHeaders: [String: String] {
        return [
            "User-Agent": InnerTubeClients.WebSafari.userAgent,
            "Origin": "https://www.youtube.com",
            "Referer": "https://www.youtube.com/"
        ]
    }

    enum CodingKeys: String, CodingKey {
        case expiresInSeconds
        case formats
        case adaptiveFormats
        case hlsManifestUrl
    }

    public init(hlsManifestUrl: String?, formats: [YouTubeStream], adaptiveFormats: [YouTubeStream], nSolver: (unsolved: String, solved: String)? = nil) {
        self.hlsManifestUrl = hlsManifestUrl
        self.formats = formats
        self.adaptiveFormats = adaptiveFormats
        self.expiresInSeconds = nil
        self.nSolver = nSolver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.formats          = try container.decodeIfPresent([YouTubeStream].self, forKey: .formats)         ?? []
        self.adaptiveFormats  = try container.decodeIfPresent([YouTubeStream].self, forKey: .adaptiveFormats) ?? []
        self.expiresInSeconds = try container.decodeIfPresent(String.self,   forKey: .expiresInSeconds)
        self.hlsManifestUrl   = try container.decodeIfPresent(String.self,   forKey: .hlsManifestUrl)
        self.nSolver          = nil
    }
}
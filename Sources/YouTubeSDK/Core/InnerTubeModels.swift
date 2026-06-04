import Foundation

// MARK: - PoTokenProvider

/// Implemented by objects that can generate a Proof-of-Origin token for a given video ID.
/// The token is used in the `/player` POST body and appended to CDN stream URLs.
/// All implementations must be safe to call concurrently for different video IDs.
public protocol PoTokenProvider: Sendable {
    func token(for videoId: String) async throws -> String
}

// MARK: - LikeStatus

/// The user's current like state for a video.
public enum LikeStatus: Sendable, Codable {
    case like
    case dislike
    case none
}

// MARK: - NextInfo

/// Combined result from the `/next` InnerTube endpoint.
public struct NextInfo: Sendable, Codable {
    public let relatedInternalVideos: [InternalVideo]
    public let likeStatus: LikeStatus
    public let chapters: [Chapter]
}

// MARK: - Comment

/// A single top-level YouTube comment returned by the `/next` continuation endpoint.
public struct Comment: Sendable, Identifiable {
    public let id: String
    public let author: String
    public let authorAvatarURL: URL?
    public let text: String
    public let likeCount: String
    public let publishedTime: String
    public let isLiked: Bool
}

// MARK: - EndCard

/// A YouTube end-screen card shown in the final seconds of a video.
/// Mirrors the `endscreen.endscreenRenderer.elements[].endscreenElementRenderer` shape.
public struct EndCard: Sendable, Identifiable, Codable {
    public enum Style: String, Sendable, Codable {
        case video = "VIDEO"
        case playlist = "PLAYLIST"
        case subscribe = "SUBSCRIBE"
        case channel = "CHANNEL"
        case link = "LINK"
        case unknown
    }

    public let id: String
    public let style: Style
    /// Target video ID — non-nil only for `.video` cards.
    public let videoId: String?
    public let title: String
    public let thumbnailURL: URL?
    /// Left edge position as a percentage (0–100) of the player width.
    public let left: Double
    /// Top edge position as a percentage (0–100) of the player height.
    public let top: Double
    /// Card width as a percentage (0–100) of the player width.
    public let width: Double
    /// Width-to-height aspect ratio (e.g. 1.778 for 16:9).
    public let aspectRatio: Double
    /// Timestamp (milliseconds from video start) when this card should appear.
    public let startMs: Int
    /// Timestamp (milliseconds from video start) when this card should disappear.
    public let endMs: Int
}

// MARK: - PlayerInfo

/// Tracking URLs returned by the YouTube `/player` endpoint.
/// Pinging these records the video in the user's official YouTube watch history.
/// Mirrors Android's `InternalVideoStatsPlaybackUrl` / `InternalVideoStatsWatchtimeUrl` in MediaServiceCore.
public struct PlaybackTrackingURLs: Sendable {
    /// Fire once (GET) when playback begins — records the view in watch history.
    public let playbackURL: URL
    /// Fire periodically during playback and on stop — records watched intervals.
    public let watchtimeURL: URL
}

public struct PlayerInfo: Sendable {
    public let video: InternalVideo
    public let formats: [InternalVideoFormat]
    public let hlsURL: URL?
    public let dashURL: URL?
    public let captionTracks: [InternalCaptionTrack]
    /// Tracking URLs for watch-history reporting; nil when unavailable (e.g. unauthenticated iOS client).
    public let trackingURLs: PlaybackTrackingURLs?
    /// End-screen cards embedded in the player response (populated for web-client fetches).
    /// Empty when the iOS client is used for primary streaming — a fallback web-client
    /// fetch is performed in PlaybackViewModel when this is empty.
    public let endCards: [EndCard]

    /// Mapping of unsolved to solved n-parameters (throttle tokens).
    /// Used by YTHLSProxyLoader to rewrite the M3U8 playlist.
    public let nSolver: (unsolved: String, solved: String)?

    /// The best stream URL to hand to AVPlayer.
    /// Prefers HLS (works natively in AVPlayer on iOS, handles adaptive quality).
    /// Falls back to combined muxed mp4 for non-HLS responses.
    public var preferredStreamURL: URL? {
        // HLS manifest — native AVPlayer ABR, alternate audio renditions, no rqh=1 issues.
        if let hls = hlsURL { return hls }
        // Muxed (combined video+audio) MP4 — identified by two codecs separated by ", "
        // e.g. `video/mp4; codecs="avc1.42001E, mp4a.40.2"` (itag=18).
        // Adaptive video-only streams also have video/mp4 but only one codec, so the
        // `", "` check correctly excludes them (they have no audio and can't be played).
        let muxed = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") &&
                $0.mimeType.contains(", ") &&
                $0.url != nil
        }
        return muxed.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// A direct MP4 URL suitable for file download (muxed video+audio).
    /// Muxed formats list two codecs separated by ", " (e.g. "avc1.xxx, mp4a.xxx"),
    /// unlike adaptive streams which have a single codec.
    /// Returns nil if no muxed MP4 with a plain URL is available.
    public var bestMuxedDownloadURL: URL? {
        let muxed = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") &&
                $0.mimeType.contains(", ") &&
                $0.url != nil
        }
        return muxed.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// Best adaptive video-only MP4 URL (single codec, no audio).
    /// Used together with bestAdaptiveAudioURL for the merge fallback.
    public var bestAdaptiveInternalVideoURL: URL? {
        let videoOnly = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") &&
                !$0.mimeType.contains(", ") &&
                $0.url != nil
        }
        return videoOnly.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// Best adaptive audio-only MP4 URL.
    /// Used together with bestAdaptiveInternalVideoURL for the merge fallback.
    public var bestAdaptiveAudioURL: URL? {
        let audioOnly = formats.filter {
            $0.mimeType.hasPrefix("audio/mp4") &&
                $0.url != nil
        }
        return audioOnly.sorted { ($0.bitrate ?? 0) > ($1.bitrate ?? 0) }.first?.url
    }

    /// Returns a copy of this `PlayerInfo` with `&pot=<token>` appended to every
    /// non-nil format URL, `hlsURL`, and `dashURL`.
    /// Call site in `PlaybackViewModel+Loading` applies this after `fetchPlayerInfo`
    /// when `InnerTubeAPI.poToken` is valid. All injection is gated on `poToken != nil`
    /// so the existing behaviour is unchanged until a provider is configured.
    public func applyingPoToken(_ token: String) -> PlayerInfo {
        func append(_ url: URL?) -> URL? {
            guard let url else { return nil }
            let sep = url.absoluteString.contains("?") ? "&" : "?"
            return URL(string: url.absoluteString + "\(sep)pot=\(token)")
        }
        let patched = formats.map { fmt in
            InternalVideoFormat(
                itag: fmt.itag,
                label: fmt.label,
                width: fmt.width,
                height: fmt.height,
                fps: fmt.fps,
                mimeType: fmt.mimeType,
                url: append(fmt.url),
                bitrate: fmt.bitrate
            )
        }
        return PlayerInfo(
            video: video,
            formats: patched,
            hlsURL: append(hlsURL),
            dashURL: append(dashURL),
            captionTracks: captionTracks,
            trackingURLs: trackingURLs,
            endCards: endCards,
            nSolver: nSolver
        )
    }

    /// Returns a copy that contains only the muxed (combined video+audio) formats,
    /// with adaptive-only formats and the dashURL removed.
    ///
    /// Used in `tryAllStreams` when loading the muxed direct-MP4 fallback: the quality
    /// picker is driven by `availableFormats` which is set from `playerInfo.formats`.
    /// If we passed the full client info (which includes adaptive-only video/audio
    /// formats), the picker would incorrectly show 720p/480p/etc even though adaptive
    /// streams are unavailable — every client's adaptive CDN URLs are rqh=1 403 or
    /// DRM-encrypted. Filtering to muxed-only ensures the picker reflects playback reality.
    public var asMuxedOnly: PlayerInfo {
        let muxedFormats = formats.filter {
            $0.mimeType.hasPrefix("video/mp4") && $0.mimeType.contains(", ") && $0.url != nil
        }
        return PlayerInfo(
            video: video,
            formats: muxedFormats,
            hlsURL: nil,
            dashURL: nil,
            captionTracks: captionTracks,
            trackingURLs: trackingURLs,
            endCards: endCards,
            nSolver: nSolver
        )
    }
}

// MARK: - APIError

public enum APIError: LocalizedError {
    case httpError(Int)
    case decodingError(String)
    case notAuthenticated
    case unavailable(String)
    case invalidURL(String)
    /// Thrown when YouTube's `/player` response indicates the request was blocked due to
    /// the source IP address (VPN, proxy, shared datacenter IP). The associated value is
    /// the raw `playabilityStatus.reason` string from the response.
    case ipBlocked(String)
    /// Thrown when the video is age-restricted or otherwise requires the user to sign in
    /// before it can be played. Unlike `unavailable`, retrying with the same credentials
    /// will not succeed — the user must authenticate first.
    case signInRequired

    public var errorDescription: String? {
        switch self {
        case let .httpError(code): "HTTP error \(code)"
        case let .decodingError(msg): "Decoding error: \(msg)"
        case .notAuthenticated: "You are not signed in"
        case let .unavailable(reason): reason
        case let .invalidURL(endpoint): "Could not build URL for endpoint: \(endpoint)"
        case .ipBlocked:
            "YouTube is temporarily blocking this network. Disable your VPN, try a different VPN server, or wait a few minutes and retry."
        case .signInRequired:
            "This video is age-restricted or requires sign in to watch."
        }
    }
}

// MARK: - Safe array subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

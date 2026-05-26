import Foundation

// MARK: - InternalVideo

/// Mirrors the Android `InternalVideo` data model.
public struct InternalVideo: Identifiable, Hashable, Codable, Sendable {
    public let id: String                   // videoId
    public var title: String
    public var channelTitle: String
    public var channelId: String?
    public var description: String?
    public var thumbnailURL: URL?
    public var duration: TimeInterval?      // seconds
    public var viewCount: Int?
    public var publishedAt: Date?
    public var isLive: Bool
    public var isUpcoming: Bool
    public var isShort: Bool
    /// True only when the API response explicitly provided a portrait thumbnail
    /// (i.e. from reelItemRenderer). False for Shorts detected via other signals
    /// (ustreamerConfig, reelWatchEndpoint, etc.) whose portrait thumbnail slot
    /// on YouTube's CDN returns a blank black image rather than a real thumb.
    public var hasPortraitThumbnail: Bool
    public var watchProgress: Double?       // 0.0 – 1.0
    public var playlistId: String?
    public var playlistIndex: Int?
    public var badges: [String]
    // Feed feedback tokens (session-scoped, from InnerTube menuRenderer)
    public var notInterestedToken: String?  // "Not interested" — hide this video
    public var dontLikeToken: String?       // "Don't like this video"
    public var hideChannelToken: String?    // "Don't recommend channel"
    // MARK: DeArrow overrides (applied from InternalVideoPreloadCache after cache consume)
    public var deArrowTitle: String?
    public var deArrowThumbnailTimestamp: Double?
    // MARK: Local playback (in-app downloads — never persisted to cache JSON)
    /// Transient local file URL set when playing a downloaded video.
    /// Excluded from `CodingKeys` — never persisted to JSON cache.
    public var localFileURL: URL? = nil
    /// `true` when this video refers to a local downloaded file rather than a remote stream.
    public var isDownloaded: Bool { localFileURL != nil }

    private enum CodingKeys: String, CodingKey {
        case id, title, channelTitle, channelId, description, thumbnailURL, duration
        case viewCount, publishedAt, isLive, isUpcoming, isShort, hasPortraitThumbnail
        case watchProgress, playlistId, playlistIndex, badges
        case notInterestedToken, dontLikeToken, hideChannelToken
        case deArrowTitle, deArrowThumbnailTimestamp
        // localFileURL intentionally omitted — runtime only, never persisted to cache JSON
    }

    public init(
        id: String,
        title: String,
        channelTitle: String,
        channelId: String? = nil,
        description: String? = nil,
        thumbnailURL: URL? = nil,
        duration: TimeInterval? = nil,
        viewCount: Int? = nil,
        publishedAt: Date? = nil,
        isLive: Bool = false,
        isUpcoming: Bool = false,
        isShort: Bool = false,
        hasPortraitThumbnail: Bool = false,
        watchProgress: Double? = nil,
        playlistId: String? = nil,
        playlistIndex: Int? = nil,
        badges: [String] = [],
        notInterestedToken: String? = nil,
        dontLikeToken: String? = nil,
        hideChannelToken: String? = nil
    ) {
        self.id = id
        self.title = title
        self.channelTitle = channelTitle
        self.channelId = channelId
        self.description = description
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.viewCount = viewCount
        self.publishedAt = publishedAt
        self.isLive = isLive
        self.isUpcoming = isUpcoming
        self.isShort = isShort
        self.hasPortraitThumbnail = hasPortraitThumbnail
        self.watchProgress = watchProgress
        self.playlistId = playlistId
        self.playlistIndex = playlistIndex
        self.badges = badges
        self.notInterestedToken = notInterestedToken
        self.dontLikeToken = dontLikeToken
        self.hideChannelToken = hideChannelToken
    }
}

// MARK: - Chapter

/// A named time-range bookmark within a video.
/// Mirrors Android's Chapter data class in YouTubeMediaItem.
public struct Chapter: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let title: String
    public let startTime: TimeInterval  // seconds from the start

    public init(title: String, startTime: TimeInterval) {
        self.id = UUID()
        self.title = title
        self.startTime = startTime
    }
}

// MARK: - Convenience helpers

public extension InternalVideo {
    var formattedDuration: String {
        guard let duration else { return "" }
        return formatDuration(duration)
    }

    var formattedViewCount: String {
        guard let viewCount else { return "" }
        switch viewCount {
        case 0..<1_000:       return "\(viewCount) views"
        case 1_000..<1_000_000: return String(format: "%.1fK views", Double(viewCount) / 1_000)
        default:              return String(format: "%.1fM views", Double(viewCount) / 1_000_000)
        }
    }

    /// High-quality thumbnail URL using YouTube's image CDN (480×360, always available).
    var highQualityThumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    /// Standard-definition thumbnail (640×480). Available for most videos.
    var sdThumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/sddefault.jpg")
    }

    /// Medium-quality thumbnail (320×180, always available — last resort).
    var mqThumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }

    /// Ordered static CDN fallbacks to try when `thumbnailURL` fails.
    /// Priority: sddefault (640×480) → hqdefault (480×360) → mqdefault (320×180).
    var thumbnailFallbackURLs: [URL] {
        [sdThumbnailURL, highQualityThumbnailURL, mqThumbnailURL].compactMap { $0 }
    }

    /// Portrait (9:16) thumbnail used for Shorts cards.
    /// YouTube generates `oardefault.jpg` (360×640) for every Short.
    var portraitThumbnailURL: URL? {
        URL(string: "https://i.ytimg.com/vi/\(id)/oardefault.jpg")
    }
}

import Foundation
import SwiftUI

// MARK: - AppSettings

/// Persisted app-wide preferences (mirrors Android `PlayerData`, `MainUIData`, `GeneralData`, etc.).
public struct AppSettings: Codable {
    // MARK: Player

    public var preferredQuality: InternalVideoQuality
    public var playbackSpeed: Double
    public var autoplayEnabled: Bool
    public var subtitlesEnabled: Bool
    public var subtitlesLanguage: String?
    public var backgroundPlaybackEnabled: Bool
    /// When `true`, the player automatically rotates to landscape when a video starts on iPhone.
    public var landscapeAlwaysPlay: Bool
    /// When `true`, Picture-in-Picture is available and the PiP button is shown in the player.
    public var pipEnabled: Bool
    /// When `true` (default), pressing back or swiping down minimizes the player to the
    /// in-app mini-player bar instead of stopping playback. When `false`, the player is
    /// dismissed and playback stops — mirrors the behaviour of a standalone player app.
    public var miniPlayerEnabled: Bool
    /// Seconds to seek backward (configurable; default 10 mirrors Android's default).
    public var seekBackSeconds: Int
    /// Seconds to seek forward (configurable; default 30 mirrors Android's default).
    public var seekForwardSeconds: Int
    /// Seconds before the player controls auto-hide after the last interaction.
    /// Mirrors Android's `PlayerData.controlsHideTimeoutMs`. Default: 4.
    public var controlsHideTimeout: Int

    /// Whether the video should fill the screen (cropping sides) or fit within bounds.
    public enum InternalVideoGravityMode: String, Codable, CaseIterable, Sendable {
        case fit // resizeAspect — letterbox/pillarbox
        case fill // resizeAspectFill — crops to fill
    }

    public var videoGravityMode: InternalVideoGravityMode

    /// When `true`, the current video replays from the start instead of advancing.
    public var loopEnabled: Bool
    /// When `true`, autoplay picks a random video from the related-videos list.
    public var shuffleEnabled: Bool

    // MARK: UI

    public var defaultSection: String
    public var compactThumbnails: Bool
    public var hideShorts: Bool
    /// When `true` (default), a per-device `visitorData` token is included in home-feed
    /// requests so YouTube tailors recommendations to this device.
    /// When `false`, the token is cleared and YouTube returns its default shared feed.
    public var perDeviceRecommendationsEnabled: Bool
    public var themeName: ThemeName
    /// Ordered list of section types visible in the sidebar/tab bar.
    /// When empty, all default sections are shown.
    public var enabledSections: [BrowseSection.SectionType]

    // MARK: General

    /// Controls whether watch history is recorded locally and fetched from YouTube.
    /// Mirrors Android's `GeneralData.historyEnabled`.
    public enum HistoryState: String, Codable, CaseIterable, Sendable {
        /// Default — history is fetched from YouTube and local positions are saved.
        case enabled
        /// History section shows nothing and local watch positions are not saved.
        case disabled
    }

    public var historyState: HistoryState

    // MARK: SponsorBlock

    /// Per-segment action that controls how each SponsorBlock category is handled.
    /// Mirrors Android's per-category action setting in `SponsorBlockData`.
    public enum SponsorBlockAction: String, Codable, CaseIterable, Sendable {
        /// Automatically skip the segment without user interaction.
        case skip
        /// Show a dismissible toast and let the user manually skip.
        case showToast
        /// Take no action — segment plays through normally.
        case nothing
    }

    public var sponsorBlockEnabled: Bool
    /// Per-category action. Categories absent from this dict are treated as `.nothing`.
    public var sponsorBlockActions: [SponsorSegment.Category: SponsorBlockAction]
    /// Minimum segment length (seconds). Segments shorter than this value are ignored.
    /// 0 means "accept all" (no filtering). Mirrors Android's `SponsorBlockData.minSegmentDuration`.
    public var sponsorBlockMinSegmentDuration: Double
    /// Channels where SponsorBlock is disabled. Key = channelId, value = display title.
    /// Mirrors Android's `SponsorBlockData.excludedChannels`.
    public var sponsorBlockExcludedChannels: [String: String]

    /// Convenience: the set of categories whose action is not `.nothing`.
    /// Passed to `SponsorBlockService.fetchSegments` so we only fetch relevant segments.
    public var activeSponsorCategories: Set<SponsorSegment.Category> {
        Set(sponsorBlockActions.compactMap { $0.value != .nothing ? $0.key : nil })
    }

    /// Returns the action for a given category (`.nothing` if not configured).
    public func sponsorAction(for category: SponsorSegment.Category) -> SponsorBlockAction {
        sponsorBlockActions[category] ?? .nothing
    }

    // MARK: Audio

    /// BCP 47 language code of the user's preferred audio track (e.g. "es", "fr", "pt-BR").
    /// `nil` means use the HLS default. Set implicitly when the user picks a track in the player.
    public var preferredAudioLanguage: String?

    /// BCP 47 language code of the user's last selected caption track (e.g. "en", "es").
    /// `nil` means captions are off. Set implicitly when the user picks a caption track in the player.
    /// Applied automatically to each new video on load.
    public var preferredCaptionLanguage: String?

    // MARK: DeArrow

    public var deArrowEnabled: Bool

    // MARK: Network

    /// Placeholder for future IPv4-forcing transport. Currently inert — no network behaviour
    /// is changed when this is `true`. The transport implementation will be added once the
    /// approach is validated on device (see docs/vpn-fix.md §Step 4).
    public var forceIPv4: Bool

    /// Optional URL of a self-hosted poToken microservice (e.g. youtube-trusted-session-generator).
    /// When set, `ServerPoTokenProvider` is wired up to `InnerTubeAPI` so poToken is injected
    /// into every `/player` request. Nil by default — no token is sent until the user configures
    /// a server URL (see docs/potoken.md §Step 5).
    public var poTokenServiceURL: URL?

    // MARK: Audio-only mode

    /// When `true`, videos load only the audio stream and display the thumbnail.
    /// ~90% data reduction vs 1080p. Live streams are excluded automatically.
    public var audioOnlyMode: Bool

    // MARK: iCloud sync

    /// When `true`, local user data (subscriptions, RSS feeds, video state, queue) is
    /// synced to iCloud via `NSUbiquitousKeyValueStore`. Defaults to `false` (opt-in).
    public var iCloudSyncEnabled: Bool

    // MARK: Types

    /// Canonical ordered list of selectable playback speeds — single source of truth.
    public static let availableSpeeds: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    /// Canonical ordered list of selectable seek-interval values (seconds) — used by Stepper on iOS and Picker on tvOS.
    public static let availableSeekOptions: [Int] = [5, 10, 15, 20, 30, 45, 60]

    public enum InternalVideoQuality: String, Codable, CaseIterable, Sendable {
        case auto
        case q2160 = "2160p"
        case q1440 = "1440p"
        case q1080 = "1080p"
        case q720 = "720p"
        case q480 = "480p"
        case q360 = "360p"
        case q240 = "240p"
        case q144 = "144p"

        /// The maximum pixel height corresponding to this quality level.
        /// Returns `nil` for `.auto` (no cap).
        public var maxHeight: Int? {
            switch self {
            case .auto: nil
            case .q144: 144
            case .q240: 240
            case .q360: 360
            case .q480: 480
            case .q720: 720
            case .q1080: 1080
            case .q1440: 1440
            case .q2160: 2160
            }
        }

        /// Returns the `InternalVideoQuality` matching an exact pixel height, or `nil` if none matches.
        public static func from(height: Int) -> InternalVideoQuality? {
            allCases.first { $0.maxHeight == height }
        }
    }

    public enum ThemeName: String, Codable, CaseIterable {
        case system = "System"
        case dark = "Dark"
        case light = "Light"

        public var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .dark: .dark
            case .light: .light
            }
        }
    }

    // MARK: Defaults

    public init() {
        self.preferredQuality = .auto
        self.playbackSpeed = 1.0
        self.autoplayEnabled = true
        self.subtitlesEnabled = false
        self.subtitlesLanguage = nil
        self.backgroundPlaybackEnabled = false
        self.landscapeAlwaysPlay = false
        self.pipEnabled = true
        self.miniPlayerEnabled = true
        self.seekBackSeconds = 10
        self.seekForwardSeconds = 30
        self.controlsHideTimeout = 4
        self.videoGravityMode = .fit
        self.loopEnabled = false
        self.shuffleEnabled = false
        self.defaultSection = BrowseSection.SectionType.home.rawValue
        self.compactThumbnails = false
        self.hideShorts = false
        self.perDeviceRecommendationsEnabled = true
        self.themeName = .system
        self.enabledSections = BrowseSection.defaultSections.map(\.type)
        self.historyState = .enabled
        self.sponsorBlockEnabled = true
        // Default actions mirror Android's SponsorBlockData defaults:
        //   sponsor / selfPromo → auto-skip; interaction / intro / preview / musicOfftopic → show toast; others → nothing
        self.sponsorBlockActions = [
            .sponsor: .skip,
            .selfPromo: .skip,
            .interaction: .showToast,
            .intro: .showToast,
            .outro: .nothing,
            .preview: .showToast,
            .filler: .nothing,
            .musicOfftopic: .showToast,
            .poiHighlight: .nothing,
        ]
        self.sponsorBlockMinSegmentDuration = 0
        self.sponsorBlockExcludedChannels = [:]
        self.preferredAudioLanguage = nil
        self.preferredCaptionLanguage = nil
        self.deArrowEnabled = false
        self.forceIPv4 = false
        self.poTokenServiceURL = nil
        self.audioOnlyMode = false
        self.iCloudSyncEnabled = false
    }
}

import Foundation

// MARK: - AudioTrack

/// A single audio rendition from an HLS manifest, exposed via AVMediaSelectionGroup.
/// AVMediaSelectionOption itself is not Sendable, so we snapshot the data we need
/// into this struct at load time; the actual option is kept in PlaybackViewModel.
public struct AudioTrack: Identifiable, Hashable, Sendable {
    /// BCP 47 language tag from the HLS rendition (e.g. "en", "es-419", "fr").
    public let id: String
    /// Localised display name (e.g. "English", "Spanish", "French").
    public let name: String
    /// ISO 639-1 / BCP 47 language code — same value as `id`.
    public let languageCode: String
    /// `true` when this is the HLS `DEFAULT=YES` rendition (the original audio).
    public let isOriginal: Bool

    public init(id: String, name: String, languageCode: String, isOriginal: Bool) {
        self.id = id
        self.name = name
        self.languageCode = languageCode
        self.isOriginal = isOriginal
    }
}

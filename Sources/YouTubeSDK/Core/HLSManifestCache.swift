import Foundation

// MARK: - HLS Manifest Cache

/// In-memory per-video-ID cache for HLS variant URL maps.
///
/// Populated by `PlaybackQualityManager` after each `fetchHLSVariantURLs` call and
/// consulted before making the network request on subsequent loads of the same video.
/// Survives video-to-video navigation (unlike `hlsVariantURLs` on the manager, which
/// is cleared on `reset()`). This eliminates the ~8 s manifest fetch when a user
/// revisits a video during the same app session.
///
/// - TTL: 30 minutes — YouTube CDN tokens typically live hours; `invalidate(for:)` handles 403s on retry.
/// - Capacity: 30 entries — matches `InternalVideoPreloadCache` LRU limit; eviction is
///   oldest-first by `fetchedAt` date.
public struct HLSManifestCache {

    // MARK: - Shared instance

    /// The shared singleton. Access is compiler-enforced to `@MainActor` at every call site.
    /// All callers (`PlaybackQualityManager`, `PlaybackViewModel`) are already `@MainActor`.
    @MainActor public static var shared = HLSManifestCache()

    // MARK: - Configuration

    public static let ttl: TimeInterval = 30 * 60
    public static let maxEntries = 30

    // MARK: - Storage

    private var store: [String: (variants: [Int: URL], fetchedAt: Date)] = [:]

    // MARK: - Interface

    /// Returns cached variant URLs for `videoId` if the entry exists and is within the TTL.
    public mutating func variants(for videoId: String) -> [Int: URL]? {
        guard let entry = store[videoId] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < Self.ttl else {
            store.removeValue(forKey: videoId)
            return nil
        }
        return entry.variants
    }

    /// Stores variant URLs for `videoId`. Evicts the oldest entry when at capacity.
    public mutating func store(_ variants: [Int: URL], for videoId: String) {
        if store.count >= Self.maxEntries,
           let oldest = store.min(by: { $0.value.fetchedAt < $1.value.fetchedAt }) {
            store.removeValue(forKey: oldest.key)
        }
        store[videoId] = (variants, Date())
    }

    /// Removes a specific video's cache entry (e.g. after a 403 to force a fresh fetch).
    public mutating func invalidate(for videoId: String) {
        store.removeValue(forKey: videoId)
    }
}

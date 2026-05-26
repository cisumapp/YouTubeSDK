import Foundation

// MARK: - LocalSubscriptionFeedCache
//
// Per-channel TTL cache for local subscription feed videos.
// Prevents redundant RSS fetches when the user navigates away and back.
// Mirrors InternalVideoPreloadCache's entry / TTL structure.
// Thread-safe: Swift actor.

public actor LocalSubscriptionFeedCache {

    // MARK: - Singleton

    public static let shared = LocalSubscriptionFeedCache()

    // MARK: - Cache entry

    private struct Entry {
        let videos: [InternalVideo]
        let fetchedAt: Date
    }

    // MARK: - TTL

    /// Cache lifetime — matches FreeTube's implicit refresh behaviour.
    static let ttl: TimeInterval = 15 * 60   // 15 minutes

    // MARK: - State

    private var cache: [String: Entry] = [:]

    public init() {}

    // MARK: - Public API

    /// Returns cached videos for `channelId` if still within TTL; nil if stale or missing.
    public func videos(for channelId: String) -> [InternalVideo]? {
        guard let entry = cache[channelId] else { return nil }
        guard Date().timeIntervalSince(entry.fetchedAt) < Self.ttl else { return nil }
        return entry.videos
    }

    /// Stores a fetch result for `channelId`, stamped with the current time.
    public func store(videos: [InternalVideo], for channelId: String) {
        cache[channelId] = Entry(videos: videos, fetchedAt: Date())
    }

    /// Removes the cached entry for `channelId` (e.g. after unfollow).
    public func invalidate(channelId: String) {
        cache.removeValue(forKey: channelId)
    }

    /// Clears all cached entries. Call on manual pull-to-refresh.
    public func invalidateAll() {
        cache.removeAll()
    }
}

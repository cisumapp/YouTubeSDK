import Foundation

// MARK: - InternalVideoDiskCache

//
// Serial-queue-backed disk cache for Phase J.
// Non-actor — accessed only from InternalVideoPreloadCache actor methods, which provide isolation.
//
// What is stored: nextInfo, endCards, sponsorSegments, deArrowBranding.
// What is NOT stored: playerInfo (CDN URLs are IP-bound) or trackingURLs (auth-sensitive).
//
// Files live at: <Caches>/st-video-cache/<sanitisedInternalVideoId>-<dataType>.json
// LRU eviction fires when directory size exceeds 20 MB.

final class InternalVideoDiskCache: @unchecked Sendable {
    // MARK: - Configuration

    static let maxBytes: Int = 20 * 1024 * 1024 // 20 MB; internal for tests
    private let queue = DispatchQueue(label: "st.disk-cache", qos: .utility)
    let cacheDir: URL // internal for tests

    // MARK: - Init

    init(cacheDir: URL? = nil) {
        if let dir = cacheDir {
            self.cacheDir = dir
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.cacheDir = base.appendingPathComponent("st-video-cache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Write (fire-and-forget)

    func store(_ value: some Encodable, videoId: String, dataType: String) {
        let url = fileURL(videoId: videoId, dataType: dataType)
        guard let data = try? JSONEncoder().encode(value) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            try? data.write(to: url, options: .atomic)
            evictIfNeeded()
        }
    }

    // MARK: - Read (synchronous, called from consume() cold path on actor context)

    func load<T: Decodable>(_ type: T.Type, videoId: String, dataType: String) -> T? {
        let url = fileURL(videoId: videoId, dataType: dataType)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: - Eviction (LRU by modification date)

    func evictIfNeeded() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys) else { return }
        var totalSize = files.compactMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        }.reduce(0, +)
        guard totalSize > Self.maxBytes else { return }
        let sorted = files.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return d1 < d2 // oldest first
        }
        for file in sorted {
            guard totalSize > Self.maxBytes else { break }
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                totalSize -= size
            }
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Auth eviction (BUG-013 fix)

    /// Removes all cached files from disk. Called by InternalVideoPreloadCache.evictAuthSensitiveData()
    /// on sign-out so nextInfo (which contains likeStatus) cannot be read back after the cache
    /// is cleared in memory.
    /// Uses queue.sync to ensure deletion completes before the caller returns, making this
    /// safe to call synchronously from actor methods that need immediate consistency.
    func removeAll() {
        queue.sync {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: self.cacheDir, includingPropertiesForKeys: nil) else { return }
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: - Helpers

    func fileURL(videoId: String, dataType: String) -> URL {
        // Sanitise to prevent path traversal: replace '/' and '..' with '_'
        let safeId = videoId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return cacheDir.appendingPathComponent("\(safeId)-\(dataType).json")
    }
}

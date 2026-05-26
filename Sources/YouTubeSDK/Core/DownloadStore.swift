import Foundation
import Observation

// MARK: - DownloadedInternalVideo

/// A record representing a video that has been downloaded to the device's local storage.
/// Persisted in `Documents/SmartTubeDownloads/manifest.json`.
public struct DownloadedInternalVideo: Codable, Sendable, Identifiable {
    public var id: String { videoId }
    public let videoId: String
    public let title: String
    public let channelTitle: String
    public let thumbnailURL: URL?
    public let duration: Double
    public let fileURL: URL
    public let downloadedAt: Date

    public init(
        videoId: String,
        title: String,
        channelTitle: String,
        thumbnailURL: URL?,
        duration: Double,
        fileURL: URL,
        downloadedAt: Date
    ) {
        self.videoId = videoId
        self.title = title
        self.channelTitle = channelTitle
        self.thumbnailURL = thumbnailURL
        self.duration = duration
        self.fileURL = fileURL
        self.downloadedAt = downloadedAt
    }

    /// Synthesises a `InternalVideo` value with `localFileURL` set to `fileURL`,
    /// suitable for handing to `PlaybackViewModel.load(video:)`.
    public var video: InternalVideo {
        var v = InternalVideo(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            thumbnailURL: thumbnailURL,
            duration: duration
        )
        v.localFileURL = fileURL
        return v
    }
}

// MARK: - DownloadStore

/// Persistent in-app registry of downloaded videos.
///
/// Downloaded MP4s are stored under `Documents/SmartTubeDownloads/<videoId>.mp4`.
/// A JSON manifest (`manifest.json` in the same directory) records metadata for
/// each download so the `DownloadsView` can display title, thumbnail, and duration
/// without opening each MP4.
///
/// `InternalVideoDownloadService` calls `add(_:)` after a successful save.
/// `DownloadsView` calls `remove(videoId:)` when the user swipes to delete.
/// `PlaybackViewModel+Loading` reads `InternalVideo.localFileURL` (populated by
/// `DownloadedInternalVideo.video`) to skip the network fetch entirely.
@Observable
@MainActor
public final class DownloadStore {
    public static let shared = DownloadStore()

    public private(set) var entries: [DownloadedInternalVideo] = []

    private var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartTubeDownloads")
    }

    private var manifestURL: URL {
        downloadsDirectory.appendingPathComponent("manifest.json")
    }

    private init() {
        loadManifest()
    }

    // MARK: - Public API

    /// The on-disk destination for a downloaded video.
    /// The `videoId` is sanitised (only alphanumerics, `-`, and `_` retained) to
    /// prevent path-traversal attacks when constructing the path component.
    public func destinationURL(for videoId: String) -> URL {
        let safe = videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return downloadsDirectory.appendingPathComponent("\(safe.isEmpty ? "download" : safe).mp4")
    }

    /// Adds or replaces a download record and persists the manifest.
    public func add(_ entry: DownloadedInternalVideo) {
        entries.removeAll { $0.videoId == entry.videoId }
        entries.append(entry)
        saveManifest()
    }

    /// Deletes the MP4 file and removes the record from the manifest.
    public func remove(videoId: String) {
        if let entry = entries.first(where: { $0.videoId == videoId }) {
            try? FileManager.default.removeItem(at: entry.fileURL)
        }
        entries.removeAll { $0.videoId == videoId }
        saveManifest()
    }

    // MARK: - Persistence

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([DownloadedInternalVideo].self, from: data) else {
            return
        }
        // Drop entries whose files were deleted outside the app.
        entries = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
    }

    private func saveManifest() {
        let fm = FileManager.default
        try? fm.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}

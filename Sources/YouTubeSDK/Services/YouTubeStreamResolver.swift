import Foundation
#if canImport(os)
import os
#endif

private let PerfLog = Logger(subsystem: appSubsystem, category: "StreamResolver")

/// A unified resolver that provides reliable playable URLs for YouTube videos.
/// It orchestrates multiple strategies: InnerTube multi-client fallbacks,
/// n-parameter descrambling, and high-quality WebView extraction.
public actor YouTubeStreamResolver {
    public static let shared = YouTubeStreamResolver()

    public let api: InnerTubeAPI

    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
    }

    /// Returns true if `videoId` looks like a valid YouTube video ID.
    /// YouTube IDs are exactly 11 characters of base64url alphabet [A-Za-z0-9_-].
    private func isValidYouTubeID(_ videoId: String) -> Bool {
        guard videoId.count == 11 else { return false }
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return videoId.unicodeScalars.allSatisfy { validChars.contains($0) }
    }

    /// Resolves a playable URL for a given video ID.
    /// Returns an HLS master manifest URL or a direct MP4 URL.
    /// - Parameters:
    ///   - videoId: The YouTube video ID.
    ///   - preferAudio: Whether to prioritize audio-only streams (e.g. for background music).
    ///   - api: Optional `InnerTubeAPI` instance to use for requests. If nil, uses the internal default.
    /// - Returns: A `PlayerInfo` containing the best playable stream.
    public func resolve(videoId: String, preferAudio: Bool = false, api: InnerTubeAPI? = nil) async throws -> PlayerInfo {
        let activeAPI = api ?? self.api
        PerfLog.notice("--- Resolving \(videoId) ---")

        // Guard: WebView and InnerTube both require a real 11-char YouTube ID.
        // Spotify/provider IDs (e.g. "spotify-liked-songs::4") will always return
        // "Video unavailable" from YouTube; skip all strategies immediately.
        guard isValidYouTubeID(videoId) else {
            PerfLog.error(" Invalid YouTube ID '\(videoId)' — skipping all strategies")
            throw APIError.unavailable("Not a valid YouTube video ID: \(videoId)")
        }

        let resolutionStart = Date()

        // 1. Try unauthenticated Android client directly (often provides muxed 360p/720p).
        // This provides the fastest possible Time-To-First-Byte because it skips complex
        // resolution flows and returns a format playable without HLS assembly.
        do {
            let start = Date()
            PerfLog.notice("Trying unauthenticated Android client for \(videoId)...")
            let info = try await activeAPI.fetchPlayerInfoAndroid(videoId: videoId)
            let elapsed = Date().timeIntervalSince(start)
            if hasPlayableStream(info, preferAudio: preferAudio) {
                PerfLog.notice(" Android fallback successful for \(videoId) in \(String(format: "%.3f", elapsed))s")
                return info
            }
            PerfLog.warning(" Android returned no playable streams for \(videoId) in \(String(format: "%.3f", elapsed))s")
        } catch {
            PerfLog.error(" Android fallback failed: \(error.localizedDescription)")
        }

        // 2. Try the "Smart" exhaustive InnerTube chain.
        // This tries iOS-Auth, WebSafari, TVEmbedded, MWEB, TVAuth, AndroidVR, etc.
        do {
            let start = Date()
            let info = try await activeAPI.fetchPlayerInfoSmart(videoId: videoId)
            let elapsed = Date().timeIntervalSince(start)
            if hasPlayableStream(info, preferAudio: preferAudio) {
                PerfLog.notice(" InnerTube successful for \(videoId) in \(String(format: "%.3f", elapsed))s")
                return info
            }
            PerfLog.warning(" InnerTube returned no playable streams for \(videoId) in \(String(format: "%.3f", elapsed))s")
        } catch {
            PerfLog.error(" InnerTube failed for \(videoId): \(error.localizedDescription)")
        }

        // 3. Try WebView HLS Extraction (High-fidelity, bypasses most bot detection).
        // Only attempt for confirmed valid YouTube IDs (already checked above).
        #if canImport(WebKit)
        do {
            let start = Date()
            PerfLog.notice("Triggering WebView extraction for \(videoId)...")
            let hlsURL = await YouTubeWebViewHLSExtractor.shared.extractHLSURL(videoId: videoId)
            let nMapping = await YouTubeWebViewHLSExtractor.shared.extractedNSolver
            let elapsed = Date().timeIntervalSince(start)

            if let hlsURL {
                PerfLog.notice(" WebView extraction success for \(videoId) in \(String(format: "%.3f", elapsed))s")

                // Re-fetch basic video metadata to return a complete PlayerInfo
                let baseInfo = try? await activeAPI.fetchPlayerInfoTVEmbedded(videoId: videoId)

                return PlayerInfo(
                    video: baseInfo?.video ?? InternalVideo(id: videoId, title: "Unknown", channelTitle: "Unknown", isLive: false),
                    formats: baseInfo?.formats ?? [],
                    hlsURL: hlsURL,
                    dashURL: nil,
                    captionTracks: baseInfo?.captionTracks ?? [],
                    trackingURLs: baseInfo?.trackingURLs,
                    endCards: baseInfo?.endCards ?? [],
                    nSolver: nMapping
                )
            }
            PerfLog.warning(" WebView extraction returned nil for \(videoId) in \(String(format: "%.3f", elapsed))s")
        } // catch {
//            PerfLog.error(" WebView extraction failed: \(error.localizedDescription)")
//        }
        #endif

        throw APIError.unavailable("Streaming failed after trying all clients (InnerTube, Android, WebView).")
    }

    private func hasPlayableStream(_ info: PlayerInfo, preferAudio: Bool) -> Bool {
        if info.hlsURL != nil { return true }
        if preferAudio, info.bestAdaptiveAudioURL != nil { return true }
        if info.bestMuxedDownloadURL != nil { return true }
        return false
    }
}

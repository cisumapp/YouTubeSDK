import Foundation
import os

private let resolverLog = Logger(subsystem: appSubsystem, category: "StreamResolver")

/// A unified resolver that provides reliable playable URLs for YouTube videos.
/// It orchestrates multiple strategies: InnerTube multi-client fallbacks,
/// n-parameter descrambling, and high-quality WebView extraction.
public actor YouTubeStreamResolver {
    public static let shared = YouTubeStreamResolver()
    
    private let api: InnerTubeAPI
    
    public init(api: InnerTubeAPI = InnerTubeAPI()) {
        self.api = api
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
        resolverLog.notice("--- Resolving \(videoId, privacy: .public) ---")
        
        // 1. Try the "Smart" exhaustive InnerTube chain.
        // This tries iOS-Auth, WebSafari, TVEmbedded, MWEB, TVAuth, AndroidVR, etc.
        do {
            let info = try await activeAPI.fetchPlayerInfoSmart(videoId: videoId)
            if hasPlayableStream(info, preferAudio: preferAudio) {
                resolverLog.notice("✅ InnerTube successful for \(videoId, privacy: .public)")
                return info
            }
            resolverLog.warning("⚠️ InnerTube returned no playable streams for \(videoId, privacy: .public)")
        } catch {
            resolverLog.error("❌ InnerTube failed for \(videoId, privacy: .public): \(error.localizedDescription)")
        }

        // 2. Try unauthenticated Android client directly (often provides muxed 360p/720p).
        do {
            resolverLog.notice("Trying unauthenticated Android client for \(videoId, privacy: .public)...")
            let info = try await activeAPI.fetchPlayerInfoAndroid(videoId: videoId)
            if hasPlayableStream(info, preferAudio: preferAudio) {
                resolverLog.notice("✅ Android fallback successful for \(videoId, privacy: .public)")
                return info
            }
        } catch {
            resolverLog.error("❌ Android fallback failed: \(error.localizedDescription)")
        }

        // 3. Try WebView HLS Extraction (High-fidelity, bypasses most bot detection).
        #if canImport(WebKit)
        do {
            resolverLog.notice("Triggering WebView extraction for \(videoId, privacy: .public)...")
            let hlsURL = try await YouTubeWebViewHLSExtractor.shared.extractHLSURL(videoId: videoId)
            let nMapping = await YouTubeWebViewHLSExtractor.shared.extractedNSolver
            
            if let hlsURL {
                resolverLog.notice("✅ WebView extraction success for \(videoId, privacy: .public)")
                
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
            resolverLog.warning("⚠️ WebView extraction returned nil for \(videoId, privacy: .public)")
        } catch {
            resolverLog.error("❌ WebView extraction failed: \(error.localizedDescription)")
        }
        #endif
        
        throw APIError.unavailable("Streaming failed after trying all clients (InnerTube, Android, WebView).")
    }
    
    private func hasPlayableStream(_ info: PlayerInfo, preferAudio: Bool) -> Bool {
        if info.hlsURL != nil { return true }
        if preferAudio && info.bestAdaptiveAudioURL != nil { return true }
        if info.bestMuxedDownloadURL != nil { return true }
        return false
    }
}

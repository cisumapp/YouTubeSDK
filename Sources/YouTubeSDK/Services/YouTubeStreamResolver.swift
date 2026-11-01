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

        // 0b. VISIONOS: AAC audio-only URLs the CDN serves to the last byte.
        //
        // Pre-signed (no JS decipher), no PO token, and — unlike IOS / MWEB / ANDROID_VR, whose
        // URLs the CDN stops serving about a fifth of the way through the file — complete. Found and
        // measured in the yt CLI's downloader.
        //
        // Not probed: VISIONOS URLs were measured to serve the whole file, and a probe cost a full
        // round trip (~550 ms) on every cold play. If one ever fails, the player's fallback ladder
        // re-resolves through the rest of this method.
        if preferAudio {
            let start = Date()
            do {
                let info = try await activeAPI.fetchPlayerInfoVisionOS(videoId: videoId)
                if info.bestAdaptiveAudioURL != nil {
                    PerfLog.notice(" VISIONOS audio for \(videoId) in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
                    return info
                }
                PerfLog.notice(" VISIONOS for \(videoId): no audio-only URL (\(String(format: "%.3f", Date().timeIntervalSince(start)))s)")
            } catch {
                PerfLog.notice(" VISIONOS failed for \(videoId): \(error.localizedDescription)")
            }
        }

        // Signature timestamp + playerID, once per session — needed from here on, not before.
        //
        // Without a playerID, `descrambleURL` returns every URL with its raw `/n=`
        // token, the CDN answers 403, and playback fails with "You do not have
        // permission to access the requested resource" — a resolve that reported
        // success and then could not play. Doing it here rather than inside the smart
        // chain means the Android attempt below is covered too.
        _ = await activeAPI.fetchSignatureTimestampIfNeeded()

        // 1. Try unauthenticated Android client directly (often provides muxed 360p/720p).
        // This provides the fastest possible Time-To-First-Byte because it skips complex
        // resolution flows and returns a format playable without HLS assembly.
        //
        // **Playable is not the same as preferred.** Android's adaptive audio is frequently
        // Opus/WebM (itag 249/250/251), which no Apple platform can play, so a response whose only
        // AVPlayer-compatible format is the muxed 360p stream is "playable" and still the worst
        // answer this ladder can produce — and returning it here meant the clients that *do* carry
        // AAC audio-only (iOS-Auth, WebSafari) were never consulted. That is why one 26-format
        // response could yield a single muxed candidate.
        //
        // So the fast path now returns immediately only when the response carries something this
        // platform wants (an HLS manifest, or an adaptive AAC audio-only format). Otherwise the
        // response is *retained* — it is a perfectly good fallback and guarantees playback — and the
        // smarter chain gets a bounded chance to do better before it is used.
        var retained: PlayerInfo?
        do {
            let start = Date()
            PerfLog.notice("Trying unauthenticated Android client for \(videoId)...")
            let info = try await activeAPI.fetchPlayerInfoAndroid(videoId: videoId)
            let elapsed = Date().timeIntervalSince(start)
            if hasPlayableStream(info, preferAudio: preferAudio) {
                if hasPreferredStream(info, preferAudio: preferAudio) {
                    PerfLog.notice(" Android fallback successful for \(videoId) in \(String(format: "%.3f", elapsed))s")
                    return info
                }
                retained = info
                // Rendered into a local first: `Logger`'s interpolation takes an autoclosure, and a
                // method call inside it would capture `self` implicitly.
                let summary = formatSummary(info)
                PerfLog.notice(
                    " Android answered for \(videoId) in \(String(format: "%.3f", elapsed))s with a playable but non-preferred format set (\(summary)) — keeping it as the fallback and asking the client chain for a compatible audio-only stream"
                )
            } else {
                PerfLog.warning(" Android returned no playable streams for \(videoId) in \(String(format: "%.3f", elapsed))s")
            }
        } catch {
            PerfLog.error(" Android fallback failed: \(error.localizedDescription)")
        }

        // 2. Try the "Smart" exhaustive InnerTube chain.
        // This tries iOS-Auth, WebSafari, TVEmbedded, MWEB, TVAuth, AndroidVR, etc.
        //
        // Bounded when Android already guaranteed playback: the retained answer means the only thing
        // this step can win is *quality*, and a quality improvement is not worth holding audio back
        // indefinitely.
        let start = Date()
        let attempt: @Sendable () async throws -> PlayerInfo = {
            try await activeAPI.fetchPlayerInfoSmart(videoId: videoId)
        }
        // With a retained answer the chain is a race against a deadline, and losing it is not an
        // error — it is the deadline doing its job. With nothing retained there is no race: the
        // chain is the only hope of playing at all, so it runs to completion and its failure is
        // reported.
        var chain: PlayerInfo?
        if retained == nil {
            do {
                chain = try await attempt()
            } catch {
                PerfLog.error(" InnerTube failed for \(videoId): \(error.localizedDescription)")
            }
        } else {
            chain = await firstResult(attempt, within: chainImprovementDeadline)
        }
        let info = chain
        let elapsed = Date().timeIntervalSince(start)
        // With a working Android answer in hand, an improvement only counts if the CDN serves it: a
        // chain answer from a client whose URLs are refused would replace audio that plays with
        // audio that does not.
        var chainAudioServes = true
        if retained != nil, let info, info.hlsURL == nil, let audio = info.bestAdaptiveAudioURL {
            // Android VR is excluded outright: measured, its URLs answer a URLSession probe and then
            // refuse AVPlayer's own reads with 403 (-12660), so a probe cannot vouch for them.
            chainAudioServes = Self.isSignedFor("ANDROID_VR", audio) ? false : await InnerTubeAPI.streamResponds(audio)
        }
        if let info, chainAudioServes, hasPlayableStream(info, preferAudio: preferAudio) {
            if hasPreferredStream(info, preferAudio: preferAudio) {
                PerfLog.notice(" InnerTube successful for \(videoId) in \(String(format: "%.3f", elapsed))s")
                return info
            }
            if retained == nil {
                PerfLog.notice(" InnerTube answered with a playable format set for \(videoId) in \(String(format: "%.3f", elapsed))s")
                return info
            }
            PerfLog.notice(" InnerTube answered for \(videoId) with no improvement over the retained Android response")
        } else {
            PerfLog.warning(" InnerTube returned no playable streams for \(videoId) in \(String(format: "%.3f", elapsed))s")
        }

        // The Android response was usable after all: play it rather than reporting the track as
        // unplayable, and skip the WebView extraction below entirely. That extraction is the most
        // expensive step in the ladder and it exists to *obtain* a stream, not to improve one.
        if let retained {
            let summary = formatSummary(retained)
            PerfLog.notice("Using the retained Android response for \(videoId) — \(summary)")
            return retained
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

    /// Loads the per-session state every resolve needs — visitorData and the player's signature
    /// timestamp — so the first play does not wait on two homepage fetches (~1.4 s measured).
    public func warmUp() async {
        async let visitor: Void = api.ensureVisitorData()
        async let timestamp = api.fetchSignatureTimestampIfNeeded()
        _ = await (visitor, timestamp)
    }

    private static func isSignedFor(_ client: String, _ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "c" }?.value == client
    }

    private func hasPlayableStream(_ info: PlayerInfo, preferAudio: Bool) -> Bool {
        if info.hlsURL != nil { return true }
        if preferAudio, info.bestAdaptiveAudioURL != nil { return true }
        if info.bestMuxedDownloadURL != nil { return true }
        return false
    }

    /// Whether this response carries the kind of stream cisum would rather play: an HLS manifest, or
    /// an audio-only MP4 (AAC) format when audio is what was asked for.
    ///
    /// This is deliberately narrower than `hasPlayableStream`, and it is the only place the ladder
    /// expresses a preference rather than a possibility. It is also *not* a quality judgement: a
    /// muxed response is not a worse *recording*, it is a worse *transport* — video cisum never
    /// displays, and no reported audio bitrate to rank with. Both answers play; this decides which
    /// one is worth asking a second client about.
    private func hasPreferredStream(_ info: PlayerInfo, preferAudio: Bool) -> Bool {
        if info.hlsURL != nil { return true }
        return preferAudio && info.bestAdaptiveAudioURL != nil
    }

    /// How long the smart chain may take to improve on a usable Android answer.
    ///
    /// A policy value, not a measurement: the chain races its own clients, so it normally answers in
    /// about a second. It is only ever spent when Android already produced something playable, which
    /// is what keeps this from being latency on the common path.
    private var chainImprovementDeadline: Duration { .milliseconds(2500) }

    /// Runs `operation`, giving up after `deadline`. `nil` means it did not finish in time — or threw,
    /// which for this use is the same answer: there is nothing better to switch to.
    ///
    /// Unstructured on purpose. A task group waits for every child before it returns, and the chain
    /// does not honour cancellation (JS solving, parallel client fallbacks), so the group version
    /// returned `nil` at the deadline *and then* blocked until the chain finished — 9–25 s observed
    /// against a 2.5 s deadline, with the chain's answer thrown away anyway.
    private func firstResult<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T,
        within deadline: Duration
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = ResumeOnce(continuation)
            let work = Task { once.resume(try? await operation()) }
            Task {
                try? await Task.sleep(for: deadline)
                once.resume(nil)
                work.cancel()
            }
        }
    }

    /// A URL-free summary of what a response actually carries, in the terms that matter for
    /// playability: how many muxed formats, audio-only formats, video-only formats and HLS manifests,
    /// with the MIME types rather than any signed URL.
    private func formatSummary(_ info: PlayerInfo) -> String {
        var containers: [String: Int] = [:]
        for format in info.formats {
            let container = format.mimeType.split(separator: ";").first.map(String.init) ?? "unknown"
            containers[container, default: 0] += 1
        }
        let listed = containers.sorted { $0.key < $1.key }.map { "\($0.value)×\($0.key)" }.joined(separator: ", ")
        return "hls=\(info.hlsURL != nil) formats=\(info.formats.count)"
            + (listed.isEmpty ? "" : " [\(listed)]")
    }
}

/// Resumes a continuation exactly once, whichever racer gets there first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

import Foundation

extension YouTubeClient {
    
    /// The smart resolver from SmartTube engine.
    /// This is used internally to obtain playable HLS manifests.
    internal var smartTubeAPI: InnerTubeAPI {
        return self.innerTube
    }

    /// Optimized video resolution using SmartTube's proven logic.
    public func resolveVideoSmart(id: String) async throws -> YouTubeVideo {
        let info = try await resolveVideo(id: id)
        
        // Map PlayerInfo (Core) to YouTubeVideo (Facade)
        var video = YouTubeVideo(id: id, title: info.video.title, viewCount: "\(info.video.viewCount ?? 0)", author: info.video.channelTitle, channelId: info.video.channelId ?? "", description: info.video.description ?? "", lengthInSeconds: "\(Int(info.video.duration ?? 0))", thumbnailURL: info.video.thumbnailURL?.absoluteString)
        
        // Map StreamingData
        let streams = info.formats.map { mapYouTubeStream($0) }
        video.streamingData = YouTubeStreamingData(
            hlsManifestUrl: info.hlsURL?.absoluteString,
            formats: streams.filter { $0.mimeType.contains(", ") },
            adaptiveFormats: streams.filter { !$0.mimeType.contains(", ") },
            nSolver: info.nSolver
        )
        
        // Map Captions
        video.captions = info.captionTracks.map { mapYouTubeCaptionTrack($0) }
        
        return video
    }
    
    /// Internal mapper for captions
    private func mapYouTubeCaptionTrack(_ internalTrack: InternalCaptionTrack) -> YouTubeCaptionTrack {
        YouTubeCaptionTrack(baseUrl: internalTrack.baseURL.absoluteString, name: internalTrack.name, languageCode: internalTrack.languageCode)
    }
    
    /// Internal mapper for streams
    private func mapYouTubeStream(_ internalFormat: InternalVideoFormat) -> YouTubeStream {
        // Note: This mapping matches the structure expected by the old SDK facade
        YouTubeStream(
            url: internalFormat.url?.absoluteString,
            itag: internalFormat.itag,
            mimeType: internalFormat.mimeType,
            bitrate: internalFormat.bitrate ?? 0,
            width: internalFormat.width,
            height: internalFormat.height,
            contentLength: nil,
            qualityLabel: internalFormat.label,
            audioQuality: nil,
            approxDurationMs: nil,
            signatureCipher: nil,
            proxyUrl: nil
        )
    }
}



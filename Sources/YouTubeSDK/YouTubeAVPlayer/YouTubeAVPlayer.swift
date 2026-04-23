//
//  YouTubeAVPlayer.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 01/01/26.
//

import AVKit
import Combine
import SwiftUI

/// A smart AVPlayer that knows how to load YouTube videos directly.
@MainActor
public class YouTubeAVPlayer: AVPlayer, ObservableObject {
    
    // MARK: - Published State
    @Published public var isLoading: Bool = false
    @Published public var currentVideo: YouTubeVideo?
    @Published public var playbackError: String?
    
    // MARK: - Configuration
    private let client: YouTubeClient
    
    public init(client: YouTubeClient = YouTubeClient()) {
        self.client = client
        super.init()
        setupAudioSession()
    }
    
    public func load(videoId: String, preferAudio: Bool = false) {
        self.isLoading = true
        self.playbackError = nil
        
        Task {
            do {
                let video = try await client.video(id: videoId)
                
                self.currentVideo = video
                
                if let streamURL = self.selectBestStream(for: video, preferAudio: preferAudio) {
                    print("▶️ Loading Stream: \(streamURL)")
                    
                    let headers: [String: String] = [
                        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                        "Referer": "https://www.youtube.com/",
                        "Origin": "https://www.youtube.com"
                    ]
                    
                    let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let item = AVPlayerItem(asset: asset)
                    self.replaceCurrentItem(with: item)
                    self.play()
                } else {
                    self.playbackError = "No playable stream found."
                }
                self.isLoading = false
            } catch {
                print("❌ YouTubePlayer Error: \(error)")
                self.playbackError = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    // MARK: - Helpers
    
    private func selectBestStream(for video: YouTubeVideo, preferAudio: Bool) -> URL? {
        // Option A: HLS (Always best for video, handles switching automatically)
        if !preferAudio, let hls = video.hlsURL {
            return hls
        }
        
        // Option B: Audio Only (For music mode)
        if preferAudio, let audio = video.bestAudioStream?.url {
            return URL(string: audio)
        }
        
        // Option C: Legacy / Fallback
        if let muxed = video.bestMuxedStream?.url {
            return URL(string: muxed)
        }
        
        return nil
    }
    
    // MARK: - Audio Session (CRITICAL FIX)
    #if os(iOS)
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playback is required for background audio and playing while silent switch is on
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("❌ Failed to set up Audio Session: \(error)")
        }
    }
    #elseif os(macOS)
    private func setupAudioSession() {
        
    }
    #endif
}

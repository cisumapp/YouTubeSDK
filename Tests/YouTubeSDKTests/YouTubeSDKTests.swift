import Testing
import Foundation
@testable import YouTubeSDK

struct YouTubeSDKTests {
    
    @Test("Fetch Video Details (Never Gonna Give You Up)")
    func fetchVideo() async throws {
        // 1. Arrange
        let client = YouTubeClient()
        let videoId = "dQw4w9WgXcQ" // The legendary ID
        
        // 2. Act
        let video = try await client.video(id: videoId)

        if let hlsURL = video.hlsURL {
            // 1. Pass directly to AVPlayer
            print(hlsURL)
        } else if let audio = video.bestAudioStream, let url = URL(string: audio.url ?? "") {
            // 2. Play high-quality audio
            print(url)
        }
        
        // 3. Assert
        #expect(video.id == videoId)
        #expect(video.title.contains("Rick Astley")) // It should be "Rick Astley - Never Gonna Give You Up"
        #expect(video.author == "Rick Astley")
        
        // Print it just to feel good
        print("✅ Fetched: \(video.title) by \(video.author)")
    }

    @Test("Fetch Home Feed")
    func fetchHomeFeed() async throws {
        let client = YouTubeClient()
        let feed = try await client.getHome()
        #expect(!feed.items.isEmpty)
    }
}

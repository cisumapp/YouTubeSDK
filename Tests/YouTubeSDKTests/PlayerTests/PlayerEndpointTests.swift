import Foundation
import Testing
@testable import YouTubeSDK

struct PlayerEndpointTests {
    @Test("Player endpoint returns playable HLS or audio URL")
    func testPlayerPlayableURL() async throws {
        // Arrange
        let client = YouTubeClient()
        let videoId = "dQw4w9WgXcQ" // Known public video

        // Act
        let video = try await client.video(id: videoId)
        #expect(video.id == videoId)

        // Assert: Ensure we have either HLS or a direct stream URL and that it is reachable.
        if let hls = video.hlsURL {
            print("Found HLS manifest: \(hls.absoluteString)")
            var request = URLRequest(url: hls)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            #expect(http.statusCode == 200)
            let prefix = String(data: data.prefix(128), encoding: .utf8) ?? ""
            #expect(prefix.contains("#EXTM3U") || prefix.contains("#EXT-X-STREAM-INF"))
        } else if let audio = video.bestAudioStream, let urlString = audio.url, let url = URL(string: urlString) {
            print("Found audio stream: \(url.absoluteString)")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            request.timeoutInterval = 20

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            #expect(http.statusCode == 200 || http.statusCode == 206)
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            #expect(contentType.contains("audio") || contentType.contains("video") || !contentType.isEmpty)
        } else if let muxed = video.bestMuxedStream, let urlString = muxed.url, let url = URL(string: urlString) {
            print("Found muxed stream: \(url.absoluteString)")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            request.timeoutInterval = 20

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            #expect(http.statusCode == 200 || http.statusCode == 206)
        } else {
            throw YouTubeError.apiError(message: "No playable stream found for \(videoId)")
        }
    }
}

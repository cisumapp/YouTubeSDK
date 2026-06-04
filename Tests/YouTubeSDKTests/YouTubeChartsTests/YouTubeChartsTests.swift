import Testing
@testable import YouTubeSDK

struct YouTubeChartsTests {
    @Test("Connect to YouTube Charts")
    func chartsConnection() async throws {
        let client = YouTubeChartsClient()
        let songs = try await client.getTopSongs()
        let artists = try await client.getTopArtists()
        #expect(!songs.isEmpty)
        #expect(!artists.isEmpty)
    }
}

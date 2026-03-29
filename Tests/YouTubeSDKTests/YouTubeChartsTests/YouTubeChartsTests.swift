import Testing
@testable import YouTubeSDK

struct YouTubeChartsTests {
    @Test("Connect to YouTube Charts")
    func testChartsConnection() async throws {
        let client = YouTubeChartsClient()
        let songs = try await client.getTopSongs()
        #expect(!songs.isEmpty)
    }
}

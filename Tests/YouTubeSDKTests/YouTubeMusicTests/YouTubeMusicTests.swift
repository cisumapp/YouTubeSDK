import Testing
@testable import YouTubeSDK

struct YouTubeMusicTests {
    @Test("Connect to YouTube Music")
    func testMusicConnection() async throws {
        let client = YouTubeMusicClient()
        let response = try await client.search("banda kaam ka")
        
        print(response)
    }

    @Test("Fetch YouTube Music Charts Sections")
    func testMusicChartsSections() async throws {
        let client = YouTubeMusicClient()
        let sections = try await client.getCharts()
        print("ytmusic_charts_sections_count=\(sections.count)")
        for section in sections.prefix(8) {
            print("ytmusic_chart_section title=\(section.title) items=\(section.items.count)")
        }
        #expect(!sections.isEmpty)
    }
}

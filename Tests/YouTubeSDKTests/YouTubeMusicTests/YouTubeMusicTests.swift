import Foundation
import Testing
@testable import YouTubeSDK

struct YouTubeMusicTests {
    @Test("Connect to YouTube Music")
    func musicConnection() async throws {
        let client = YouTubeMusicClient()
        let response = try await client.search("banda kaam ka")

        YouTubeLog.debug("ytmusic_search_count=\(response.count)")
    }

    @Test("Fetch YouTube Music Charts Sections")
    func musicChartsSections() async throws {
        let client = YouTubeMusicClient()
        let sections = try await client.getCharts()
        YouTubeLog.debug("ytmusic_charts_sections_count=\(sections.count)")
        for section in sections.prefix(8) {
            YouTubeLog.debug("ytmusic_chart_section title=\(section.title) items=\(section.items.count)")
        }
        #expect(!sections.isEmpty)
    }

    @Test("Fetch paginated YouTube Music home page")
    func musicHomePage() async throws {
        let client = YouTubeMusicClient()
        let page = try await client.getHomePage()

        #expect(!page.sections.isEmpty || !page.items.isEmpty || page.continuationToken != nil)

        if let token = page.continuationToken, !token.isEmpty {
            _ = try await client.getHomeContinuation(token: token)
        }
    }

    /// A row as a filtered search returns it (trimmed from a live "radiohead" response).
    private static func row(_ name: String, _ details: [String], browseID: String, pageType: String) -> [String: Any] {
        [
            "navigationEndpoint": ["browseEndpoint": [
                "browseId": browseID,
                "browseEndpointContextSupportedConfigs": ["browseEndpointContextMusicConfig": ["pageType": pageType]],
            ]],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": name]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": details.map { ["text": $0] }]]],
            ],
            "thumbnail": ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": [["url": "https://lh3.googleusercontent.com/a=w120-h120"]]]]],
        ]
    }

    @Test("Filtered search rows parse into artists and playlists")
    func parseListItems() async throws {
        let response: [String: Any] = ["contents": ["musicShelfRenderer": ["contents": [
            ["musicResponsiveListItemRenderer": Self.row("Radiohead", ["Artist", " • ", "204M monthly audience"], browseID: "UCr_iyUANcn9OX_yy9piYoLw", pageType: "MUSIC_PAGE_TYPE_ARTIST")],
            ["musicResponsiveListItemRenderer": Self.row("Radiohead - Greatest Hits", ["Ali Aideel Ismail", " • ", "341K views"], browseID: "VLPLUwsfagaCki8ibIU", pageType: "MUSIC_PAGE_TYPE_PLAYLIST")],
            ["musicResponsiveListItemRenderer": Self.row("Creep", ["Song"], browseID: "MPREb_x", pageType: "MUSIC_PAGE_TYPE_ALBUM")],
        ]]]]
        let items = await YouTubeMusicClient().parseListItems(from: try JSONSerialization.data(withJSONObject: response))

        #expect(items.count == 2)
        guard case let .artist(artist) = items.first, case let .playlist(playlist) = items.last else {
            Issue.record("expected an artist then a playlist, got \(items)")
            return
        }
        #expect(artist.id == "UCr_iyUANcn9OX_yy9piYoLw")
        #expect(artist.name == "Radiohead")
        #expect(artist.subscriberCount == "204M monthly audience")
        #expect(artist.thumbnailURL != nil)
        #expect(playlist.id == "VLPLUwsfagaCki8ibIU")
        #expect(playlist.title == "Radiohead - Greatest Hits")
        #expect(playlist.author == "Ali Aideel Ismail")
    }

    @Test("Search YouTube Music artists and playlists")
    func searchArtistsAndPlaylists() async throws {
        let client = YouTubeMusicClient()
        let artists = try await client.searchArtists("radiohead")
        let playlists = try await client.searchPlaylists("radiohead")
        #expect(artists.first?.name == "Radiohead")
        #expect(!playlists.isEmpty)
    }

    @Test("Artist page: header and every section's tiles")
    func artistPage() async throws {
        let detail = try await YouTubeMusicClient().getArtist(browseId: "UCr_iyUANcn9OX_yy9piYoLw")
        #expect(detail.name == "Radiohead")
        #expect(detail.about?.isEmpty == false)
        #expect(detail.photoURL != nil)
        #expect(detail.audience?.contains("monthly") == true)

        func section(_ prefix: String) -> [YouTubeMusicItem] {
            detail.sections.first { $0.title.hasPrefix(prefix) }?.items ?? []
        }
        #expect(!section("Top songs").isEmpty)
        #expect(section("Albums").contains { if case let .album(album) = $0 { album.year != nil } else { false } })
        #expect(section("Singles").contains { if case .album = $0 { true } else { false } })
        #expect(section("Videos").contains { if case .song = $0 { true } else { false } })
        #expect(section("Playlists").contains { if case .playlist = $0 { true } else { false } })
        #expect(section("Fans might also like").contains { if case .artist = $0 { true } else { false } })
    }
}

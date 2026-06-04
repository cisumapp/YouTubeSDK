import XCTest
@testable import YouTubeSDK

final class LiveAPITests: XCTestCase {
    @MainActor
    func testHomeFeed() async throws {
        // Setup storage first
        struct MockStorage: YouTubeSDKStorage {
            func save(_: String, key _: String) {}
            func load(key _: String) -> String? {
                nil
            }

            func delete(key _: String) {}
        }
        YouTubeSDKConfig.storage = MockStorage()

        let youtube = YouTube.shared
        do {
            let continuation = try await youtube.main.getHome()
            XCTAssertFalse(continuation.items.isEmpty, "Home feed should not be empty")
            print("✅ Home feed fetched: \(continuation.items.count) items")
        } catch {
            XCTFail("Home feed fetch failed with error: \(error)")
        }
    }

    @MainActor
    func testMusicSearch() async throws {
        struct MockStorage: YouTubeSDKStorage {
            func save(_: String, key _: String) {}
            func load(key _: String) -> String? {
                nil
            }

            func delete(key _: String) {}
        }
        YouTubeSDKConfig.storage = MockStorage()

        let youtube = YouTube.shared
        do {
            let results = try await youtube.music.search("vultures kany west")
            XCTAssertFalse(results.isEmpty, "Music search results should not be empty")
            print("✅ Music search successful: \(results.count) songs")
        } catch {
            XCTFail("Music search failed with error: \(error)")
        }
    }

    @MainActor
    func testVideoResolution() async throws {
        struct MockStorage: YouTubeSDKStorage {
            func save(_: String, key _: String) {}
            func load(key _: String) -> String? {
                nil
            }

            func delete(key _: String) {}
        }
        YouTubeSDKConfig.storage = MockStorage()

        let youtube = YouTube.shared
        do {
            // Test with a known video ID
            let video = try await youtube.main.video(id: "LlwHphMhUOo")
            XCTAssertNotNil(video.streamingData, "Streaming data should be present")
            XCTAssertTrue(video.hlsURL != nil || !video.streamingData!.formats.isEmpty, "Should have HLS or adaptive formats")
            print("✅ Video resolution successful: \(video.title) (HLS: \(video.hlsURL != nil))")
        } catch {
            XCTFail("Video resolution failed with error: \(error)")
        }
    }

    @MainActor
    func testCharts() async throws {
        struct MockStorage: YouTubeSDKStorage {
            func save(_: String, key _: String) {}
            func load(key _: String) -> String? {
                nil
            }

            func delete(key _: String) {}
        }
        YouTubeSDKConfig.storage = MockStorage()

        let youtube = YouTube.shared
        do {
            let results = try await youtube.charts.getTopSongs(country: "IN")
            XCTAssertFalse(results.isEmpty, "Charts should not be empty")
            print("✅ Charts successful: \(results.count) items")
        } catch {
            XCTFail("Charts failed with error: \(error)")
        }
    }
}

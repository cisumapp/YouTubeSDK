import Testing
@testable import YouTubeSDK
import Foundation

struct CoreTests {

    // MARK: - Logic Tests
    
    @Test("Verifies that InnerTubeContext generates the correct JSON structure")
    func contextGeneration() {
        // 1. Arrange
        let config = ClientConfig.android
        let context = InnerTubeContext(client: config, gl: "IN", hl: "en")
        
        // 2. Act
        let body = context.body
        let contextDict = body["context"] as? [String: Any]
        let clientDict = contextDict?["client"] as? [String: Any]
        
        // 3. Assert (Notice the cleaner syntax)
        #expect(clientDict != nil, "The body should contain a 'context.client' object")
        #expect(clientDict?["clientName"] as? String == "ANDROID")
        #expect(clientDict?["gl"] as? String == "IN")
        #expect(context.headers["User-Agent"] == config.userAgent)
    }

    @Test("Charts analytics client identity contract")
    func chartsAnalyticsContextContract() {
        let context = InnerTubeContext(client: .webMusicAnalytics)
        let body = context.body
        let contextDict = body["context"] as? [String: Any]
        let clientDict = contextDict?["client"] as? [String: Any]

        #expect(context.headers["X-YouTube-Client-Name"] == "31")
        #expect(context.headers["X-YouTube-Client-Version"] == "2.0")
        #expect(clientDict?["clientName"] as? String == "WEB_MUSIC_ANALYTICS")
        #expect(clientDict?["clientVersion"] as? String == "2.0")
    }

    // MARK: - Integration Tests
    
    @Test("Real Network Call (Guide Endpoint)")
    func networkCall() async throws {
        // 1. Arrange
        let context = InnerTubeContext(client: .ios)
        let client = NetworkClient(context: context)
        
        // 2. Act & Assert
        // In Swift Testing, if a function throws, the test fails automatically.
        // We just need to try the call.
        let _: EmptyJSONResponse = try await client.send("v1/guide", body: [:])
        
        // If we reach this line, it means no error was thrown -> Success!
    }
}

// Helper
struct EmptyJSONResponse: Decodable {}

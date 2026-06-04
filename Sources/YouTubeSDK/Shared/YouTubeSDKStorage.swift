import Foundation

public protocol YouTubeSDKStorage: Sendable {
    func save(_ value: String, key: String)
    func load(key: String) -> String?
    func delete(key: String)
}

public struct YouTubeSDKConfig: Sendable {
    public nonisolated(unsafe) static var storage: YouTubeSDKStorage?
}

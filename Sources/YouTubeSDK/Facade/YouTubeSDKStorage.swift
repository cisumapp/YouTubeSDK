import Foundation

/// A platform-agnostic protocol for secure storage.
/// Applications must implement this (e.g., using Keychain on iOS, 
/// or other encrypted storage on other platforms) and set it in `YouTubeSDKConfig`.
public protocol YouTubeSDKStorage: Sendable {
    func save(_ value: String, key: String)
    func load(key: String) -> String?
    func delete(key: String)
}

/// Global configuration for the YouTubeSDK.
public enum YouTubeSDKConfig {
    /// The storage provider used for OAuth tokens and cookies.
    /// This MUST be set before using any authenticated features of the SDK.
    /// It is nonisolated(unsafe) because it is intended to be set once at app launch.
    public nonisolated(unsafe) static var storage: (any YouTubeSDKStorage)?
}

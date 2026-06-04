//
//  Clients.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

/// Defines the static identity of a YouTube Client.
/// This struct holds the "Magic Strings" required to mimic an official app.
/// https://github.com/zerodytrash/YouTube-Internal-Clients <- The goat
public struct ClientConfig: Sendable {
    public let name: String // The internal client name (e.g., "IOS", "WEB_REMIX")
    public let version: String // The app version (e.g., "19.10.5")
    public let apiKey: String // The Google API Key
    public let userAgent: String // The User-Agent header string
    public let clientNameID: String // The numeric ID used in some stats logs
    public let androidSdkVersion: Int?

    public init(name: String, version: String, apiKey: String, userAgent: String, clientNameID: String, androidSdkVersion: Int? = nil) {
        self.name = name
        self.version = version
        self.apiKey = apiKey
        self.userAgent = userAgent
        self.clientNameID = clientNameID
        self.androidSdkVersion = androidSdkVersion
    }

    // MARK: - The Golden List of Presets

    /// The Standard Web Client. Best for Charts and Public Data.
    public static let web = ClientConfig(
        name: "WEB",
        version: "2.20260206.01.00",
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        clientNameID: "1"
    )

    /// The YouTube Music Web Client. Best for Lyrics and Metadata.
    public static let webRemix = ClientConfig(
        name: "WEB_REMIX",
        version: "1.20240308.00.00",
        apiKey: "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30", // From zerodytrash (Web Music)
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        clientNameID: "67"
    )

    public static let webMusicAnalytics = ClientConfig(
        name: "WEB_MUSIC_ANALYTICS",
        version: "2.0",
        apiKey: "AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30", // From zerodytrash (Web Music)
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
        clientNameID: "31"
    )

    /// The standard iOS Client. Best for generic Video and Search.
    /// Version and User-Agent match SmartTube's working config (21.02.3, iPhone16,2, dynamic OS).
    public static var ios: ClientConfig {
        ClientConfig(
            name: "iOS",
            version: "21.02.3",
            apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
            userAgent: iosUserAgent,
            clientNameID: "5"
        )
    }

    private static var iosUserAgent: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVer = v.patchVersion == 0
            ? "\(v.majorVersion)_\(v.minorVersion)"
            : "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
        return "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS \(osVer) like Mac OS X;)"
    }

    /// The YouTube Music Native Client. Best for High-Quality Audio.
    public static let iosMusic = ClientConfig(
        name: "IOS_MUSIC",
        version: "6.43.52", // Recent stable version
        apiKey: "AIzaSyBAETezhkwP0ZWA02RsqT1zu78Fpt0bC_s", // From zerodytrash (iOS Music)
        userAgent: "com.google.ios.youtube/20.11.6 (iPhone10,4; U; CPU iOS 16_7_7 like Mac OS X)",
        clientNameID: "26"
    )

    /// The Android Client. Reliable backup for Video.
    public static let android = ClientConfig(
        name: "ANDROID",
        version: "21.02.35",
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        userAgent: "com.google.android.youtube/21.02.35 (Linux; U; Android 11) gzip",
        clientNameID: "3",
        androidSdkVersion: 30
    )

    /// The YouTube Music Native Client. Best for High-Quality Audio.
    public static let androidMusic = ClientConfig(
        name: "ANDROID_MUSIC",
        version: "6.43.52", // Recent stable version
        apiKey: "AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI", // From zerodytrash (Android Music)
        userAgent: "com.google.android.apps.youtube.music/6.43.52 (Linux; U; Android 13; en_US) gzip",
        clientNameID: "21"
    )

    /// The Web Embedded Player Client. Returns all formats with signatureCipher (forces decipher challenge).
    /// Based on demos youtube-nocookie.com / js-player requests.
    /// Uses the same API key as WEB.
    public static var webEmbedded: ClientConfig {
        ClientConfig(
            name: "WEB_EMBEDDED_PLAYER",
            version: "2.20260519.01.00",
            apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
            userAgent: webEmbeddedUserAgent,
            clientNameID: "56"
        )
    }

    private static var webEmbeddedUserAgent: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVer = v.patchVersion == 0
            ? "\(v.majorVersion)_\(v.minorVersion)"
            : "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVer) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(v.majorVersion).\(v.minorVersion) Mobile/15E148 Safari/604.1"
    }

    /// The TV Client. Essential for the "Code" Authentication flow.
    public static let tv = ClientConfig(
        name: "TVHTML5",
        version: "7.20260311.12.00",
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        clientNameID: "7"
    )

    /// The Android VR (Oculus Quest) client. Does NOT require a PO token for adaptive audio.
    /// Per yt-dlp research (May 2026), usable as fallback in audio-only mode.
    public static let androidVR = ClientConfig(
        name: "ANDROID_VR",
        version: "1.65.10",
        apiKey: "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12; Build/SQ3A.220705.001.B1) gzip",
        clientNameID: "28"
    )
}

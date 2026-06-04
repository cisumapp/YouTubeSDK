//
//  InnerTubeContext.swift
//  YouTubeSDK
//
//  Responsible for building the JSON payload required for every InnerTube request.
//

import Foundation

public struct InnerTubeContext: Sendable {
    private let client: ClientConfig
    public let cookies: String?
    public let accessToken: String?

    private let gl: String
    private let hl: String
    private let onBehalfOfUser: String?
    private let poToken: String?

    public init(
        client: ClientConfig,
        cookies: String? = nil,
        accessToken: String? = nil,
        gl: String = "US",
        hl: String = "en",
        onBehalfOfUser: String? = nil,
        poToken: String? = nil
    ) {
        self.client = client
        self.cookies = cookies
        self.accessToken = accessToken
        self.gl = gl
        self.hl = hl
        self.onBehalfOfUser = onBehalfOfUser?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.poToken = poToken
    }

    public var apiKey: String {
        client.apiKey
    }

    public var headers: [String: String] {
        var defaultHeaders = [
            "User-Agent": client.userAgent,
            "Content-Type": "application/json",
            "X-YouTube-Client-Name": client.clientNameID,
            "X-YouTube-Client-Version": client.version,
        ]

        if let cookies, !cookies.isEmpty, client.name == "TVHTML5" || client.name.contains("WEB") {
            defaultHeaders["Cookie"] = cookies
        }

        if let accessToken, !accessToken.isEmpty, client.name == "TVHTML5" {
            defaultHeaders["Authorization"] = "Bearer \(accessToken)"
        }

        return defaultHeaders
    }

    public var body: [String: Any] {
        var clientDict: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "gl": gl,
            "hl": hl,
        ]

        if client.name == "iOS" {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let osVer = v.patchVersion == 0
                ? "\(v.majorVersion).\(v.minorVersion)"
                : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            clientDict["deviceMake"] = "Apple"
            clientDict["deviceModel"] = "iPhone16,2"
            clientDict["osName"] = "iPhone"
            clientDict["osVersion"] = osVer
            clientDict["clientScreen"] = "WATCH"
        }

        if client.name == "WEB_EMBEDDED_PLAYER" {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let osVer = v.patchVersion == 0
                ? "\(v.majorVersion)_\(v.minorVersion)"
                : "\(v.majorVersion)_\(v.minorVersion)_\(v.patchVersion)"
            clientDict["deviceMake"] = "Apple"
            clientDict["deviceModel"] = "iPhone"
            clientDict["osName"] = "iPhone"
            clientDict["osVersion"] = osVer
            clientDict["platform"] = "MOBILE"
            clientDict["clientFormFactor"] = "UNKNOWN_FORM_FACTOR"
            clientDict["originalUrl"] = "https://www.youtube-nocookie.com/embed?enablejsapi=1&autoplay=1&controls=0&fs=0&rel=0"
            clientDict["acceptHeader"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        }

        // Android client — exact params from SmartTubeIOS / yt-dlp to avoid 400.
        if client.name == "ANDROID" {
            if let sdk = client.androidSdkVersion {
                clientDict["androidSdkVersion"] = sdk
            }
            clientDict["osName"] = "Android"
            clientDict["osVersion"] = "11"
        }

        // Android VR (Oculus Quest) — used as unauthenticated audio-only fallback.
        if client.name == "ANDROID_VR" {
            clientDict["osName"] = "Android"
            clientDict["osVersion"] = "12"
        }

        var context: [String: Any] = ["client": clientDict]
        if let onBehalfOfUser {
            context["user"] = ["onBehalfOfUser": onBehalfOfUser]
        }
        var body: [String: Any] = ["context": context]
        // poToken goes at the TOP LEVEL of the body, not nested in context
        if let poToken {
            body["serviceIntegrityDimensions"] = ["poToken": poToken]
        }
        return body
    }
}

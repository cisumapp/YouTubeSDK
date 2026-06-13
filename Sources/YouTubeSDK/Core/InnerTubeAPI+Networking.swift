import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os)
import os
#endif

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

// MARK: - Networking

extension InnerTubeAPI {
    // MARK: - Visitor Data

    /// Ensures that `visitorData` is populated by hitting YouTube's homepage if it is currently nil.
    /// Many InnerTube endpoints return HTTP 400 when `visitorData` is missing.
    func ensureVisitorData() async {
        if visitorData != nil { return }

        // Use a detached task to avoid cancellation by the caller.
        // This ensures the seeding completes even if the original search/browse request is cancelled.
        await Task.detached { [weak self] in
            guard let self else { return }
            await _ensureVisitorData()
        }.value
    }

    private func _ensureVisitorData() async {
        guard visitorData == nil else { return }
        tubeLog.notice("ensureVisitorData: seeding missing visitorData from homepage...")
        guard let url = URL(string: "https://www.youtube.com/") else { return }
        var request = URLRequest(url: url)
        // Desktop Safari UA for reliable visitorData seeding
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse,
               let vd = http.value(forHTTPHeaderField: "X-Goog-Visitor-Id")
            {
                visitorData = vd
                tubeLog.notice("ensureVisitorData:  seeded visitorData (len=\(vd.count))")
            } else if let html = String(data: data, encoding: .utf8) {
                // Protobuf visitorData is often in ytcfg.
                let pattern = #""visitorData"\s*:\s*"([^"]+)""#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   let range = Range(match.range(at: 1), in: html)
                {
                    let vd = String(html[range])
                    visitorData = vd
                    tubeLog.notice("ensureVisitorData:  seeded visitorData from html (len=\(vd.count))")
                }
            }
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                // Should be rare now with Task.detached
            } else {
                tubeLog.error("ensureVisitorData: failed — \(error)")
            }
        }
    }

    // MARK: - signatureTimestamp fetch

    /// Returns the current YouTube player `signatureTimestamp` (STS), fetching and
    /// caching it from YouTube's homepage if not already stored or if the cache has
    /// expired (TTL = 24 hours). The STS only changes when YouTube updates its player
    /// JS (every 1-2 weeks), so a 24hr TTL eliminates most redundant homepage fetches
    /// while still being safe against stale values. The STS is required by the TV
    /// authenticated player request to validate the player JS version — YouTube returns
    /// "The page needs to be reloaded" when it is absent or stale.
    /// Returns `nil` silently on network failure so callers can proceed without it.
    func fetchSignatureTimestampIfNeeded() async -> Int? {
        if let sts = signatureTimestamp,
           let fetchedAt = signatureTimestampFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 86400
        {
            return sts
        }
        guard let url = URL(string: "https://www.youtube.com/") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.setValue(InnerTubeClients.Web.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await session.data(for: request)
            // "STS" appears at byte ~606 KB in YouTube's homepage — scan the full page.
            guard let html = String(data: data, encoding: .utf8) else { return nil }

            // 1. Extract STS
            let stsPattern = #""STS"\s*:\s*(\d+)"#
            if let regex = try? NSRegularExpression(pattern: stsPattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html),
               let sts = Int(html[range])
            {
                signatureTimestamp = sts
                signatureTimestampFetchedAt = Date()
                tubeLog.notice("Fetched signatureTimestamp (STS): \(sts)")
            } else {
                tubeLog.error(" signatureTimestamp: pattern not found in homepage response")
            }

            // 2. Extract Player ID (for n-descramble)
            // Match /s/player/XXXXXXXX/ (8 lowercase hex chars).
            let playerPattern = #"/s/player/([a-f0-9]{8})/"#
            if let regex = try? NSRegularExpression(pattern: playerPattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html)
            {
                let pid = String(html[range])
                playerID = pid
                tubeLog.notice("Fetched playerID: \(pid)")
            }

            return signatureTimestamp
        } catch {
            tubeLog.error(" signatureTimestamp fetch failed: \(error)")
            return nil
        }
    }

    // MARK: - Body builders

    func makeBody(client: [String: Any], continuationToken: String? = nil, includeVisitorData: Bool = false, includePoToken: Bool = false) -> [String: Any] {
        var body: [String: Any] = ["context": client]
        if let token = continuationToken {
            body["continuation"] = token
        }
        if includeVisitorData, let visitor = visitorData {
            body["visitorData"] = visitor
        }
        if includePoToken, let pot = poToken {
            body["serviceIntegrityDimensions"] = ["poToken": pot]
        }
        return body
    }

    // MARK: - Attestation

    /// Fetches a proof-of-origin attestation token via YouTube's att/get endpoint.
    func fetchAttestationToken(videoId: String) async -> String? {
        guard let token = authToken else { return nil }

        let body: [String: Any] = [
            "context": ["client": (tvClientContext["client"] as? [String: Any]) ?? [:]],
            "contentBindingContext": ["videoId": videoId],
        ]

        do {
            let json = try await post(
                endpoint: "att/get",
                body: body,
                headers: [
                    "X-YouTube-Client-Name": InnerTubeClients.TV.nameID,
                    "X-YouTube-Client-Version": InnerTubeClients.TV.version,
                    "User-Agent": InnerTubeClients.TV.userAgent,
                    "Authorization": "Bearer \(token)",
                ],
                useAuth: false // We handled auth manually in headers
            )

            guard let attToken = json["attestationToken"] as? String, !attToken.isEmpty else {
                return nil
            }
            tubeLog.notice("att/get:  attestationToken obtained")
            return attToken
        } catch {
            tubeLog.notice("att/get: failed — \(error)")
            return nil
        }
    }

    // MARK: - Transport

    /// Core InnerTube POST request — used by all client variants.
    func post(
        endpoint: String,
        body: [String: Any],
        headers: [String: String] = [:],
        useAuth: Bool = false
    ) async throws -> [String: Any] {
        await ensureVisitorData()

        // Pick the correct base URL. player/att/get endpoints use playerBaseURL (googleapis.com).
        // Standard browse/search endpoints use baseURL (googleapis.com).
        // Some specialized web clients use www.youtube.com (handled via Origin/Referer headers).
        let targetBase = endpoint.contains("player") || endpoint.contains("att/") ? playerBaseURL : baseURL

        guard var comps = URLComponents(url: targetBase.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL(endpoint)
        }

        let resolvedToken = useAuth ? authToken : nil
        if resolvedToken == nil, headers["Authorization"] == nil {
            comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        }
        guard let url = comps.url else { throw APIError.invalidURL(endpoint) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")

        // Default headers (Web client)
        request.setValue(InnerTubeClients.Web.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.Web.version, forHTTPHeaderField: "X-YouTube-Client-Version")

        // Apply custom header overrides
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let token = resolvedToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let vd = visitorData {
            request.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            tubeLog.error(" HTTP \(statusCode) for /\(endpoint)")
            throw APIError.httpError(statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError("Root JSON is not a dictionary")
        }

        if let error = json["error"] as? [String: Any] {
            tubeLog.error(" API error in /\(endpoint): \(String(describing: error["message"] ?? error))")
        }

        return json
    }

    func postPlayer(body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: "player",
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.iOS.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.iOS.version,
                "User-Agent": iosUserAgent,
            ]
        )
    }

    func postPlayerAuthenticated(body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: "player",
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.iOS.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.iOS.version,
                "User-Agent": iosUserAgent,
            ],
            useAuth: true
        )
    }

    func postAndroidVR(body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: "player",
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.AndroidVR.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.AndroidVR.version,
                "User-Agent": InnerTubeClients.AndroidVR.userAgent,
            ]
        )
    }

    func postAndroid(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: endpoint,
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.Android.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.Android.version,
                "User-Agent": InnerTubeClients.Android.userAgent,
            ]
        )
    }

    func postTVEmbedded(body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: "player",
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.TVEmbedded.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.TVEmbedded.version,
                "User-Agent": InnerTubeClients.Web.userAgent,
                "Origin": "https://www.youtube.com",
                "Referer": "https://www.youtube.com/",
            ]
        )
    }

    func postMWEB(body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: "player",
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.MWEB.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.MWEB.version,
                "User-Agent": InnerTubeClients.MWEB.userAgent,
                "Origin": "https://www.youtube.com",
                "Referer": "https://m.youtube.com/",
            ]
        )
    }

    func postWebSafari(body: [String: Any], visitorIdOverride: String? = nil) async throws -> [String: Any] {
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent("player"),
            resolvingAgainstBaseURL: false
        ) else {
            throw APIError.invalidURL("player")
        }
        comps.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = comps.url else { throw APIError.invalidURL("player") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue(InnerTubeClients.WebSafari.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(InnerTubeClients.WebSafari.nameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(InnerTubeClients.WebSafari.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        // SAPISID auth for postWebSafari.
        // When SAPISID is available (recovered from WKWebView propagated cookies), use
        // SAPISIDHASH auth so YouTube treats the request as authenticated — returning rqh=0
        // adaptive stream URLs that the CDN serves without pot= enforcement.
        // Without auth, YouTube returns rqh=1 URLs that require pot= and still 403 on the
        // CDN probe when match=false (webVD ≠ apiVD). With SAPISID, Path A wins reliably.
        // Falls back to Bearer+AuthUser (same as yt-dlp web OAuth pattern) when SAPISID is nil.
        let authStatus: String
        if let sid = sapisid {
            request.setValue(InnerTubeAPI.sapisidhash(sapisid: sid), forHTTPHeaderField: "Authorization")
            request.setValue("1", forHTTPHeaderField: "X-Origin")
            authStatus = "SAPISIDHASH"
        } else if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
            authStatus = "Bearer+AuthUser"
        } else {
            authStatus = "unauthenticated"
        }
        // Use the override visitor ID (from WKWebView guide call) when provided, so the
        // X-Goog-Visitor-Id header matches the context.client.visitorData in the body and
        // the minted BotGuard pot= token identifier — required for CDN URL validation.
        let effectiveVD = visitorIdOverride ?? visitorData
        if let vd = effectiveVD {
            request.setValue(vd, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let videoId = body["videoId"] as? String ?? ""
        tubeLog.notice("POST /player [WebSafari] videoId=\(videoId) auth=\(authStatus)")
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            tubeLog.error(" HTTP \(statusCode) for /player [WebSafari]")
            throw APIError.httpError(statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tubeLog.error(" Non-dictionary JSON root for /player [WebSafari]")
            throw APIError.decodingError("Root JSON is not a dictionary")
        }
        if let error = json["error"] as? [String: Any] {
            tubeLog.error(" API error in /player [WebSafari]: \(String(describing: error["message"] ?? error))")
        } else {
            let topKeys = Array(json.keys.prefix(6))
            tubeLog.notice(" /player [WebSafari] HTTP \(statusCode) keys: \(topKeys)")
        }
        return json
    }

    func postWebAuthenticated(body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: "player",
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.Web.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.Web.version,
                "User-Agent": InnerTubeClients.Web.userAgent,
                "X-Goog-AuthUser": "0",
            ],
            useAuth: true
        )
    }

    /// WEB_CREATOR (nameID=62) player request on www.youtube.com.
    func postWebCreator(body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: "player",
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.WebCreator.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.WebCreator.version,
                "User-Agent": InnerTubeClients.Web.userAgent,
            ],
            useAuth: true
        )
    }

    func postTVCategory(endpoint: String, body: [String: Any]) async throws -> [String: Any] {
        try await post(
            endpoint: endpoint,
            body: body,
            headers: [
                "X-YouTube-Client-Name": InnerTubeClients.TV.nameID,
                "X-YouTube-Client-Version": InnerTubeClients.TV.version,
                "User-Agent": InnerTubeClients.TV.userAgent,
            ]
        )
    }

    func postTV(
        endpoint: String,
        body: [String: Any],
        useAuth: Bool = true,
        explicitBearerToken: String? = nil
    ) async throws -> [String: Any] {
        var h: [String: String] = [
            "X-YouTube-Client-Name": InnerTubeClients.TV.nameID,
            "X-YouTube-Client-Version": InnerTubeClients.TV.version,
            "User-Agent": InnerTubeClients.TV.userAgent,
        ]
        if let token = explicitBearerToken {
            h["Authorization"] = "Bearer \(token)"
        }
        return try await post(
            endpoint: endpoint,
            body: body,
            headers: h,
            useAuth: explicitBearerToken == nil ? useAuth : false
        )
    }
}

// MARK: - SAPISIDHASH helper

extension InnerTubeAPI {
    /// Computes the SAPISIDHASH Authorization header value for www.youtube.com web-client requests.
    static func sapisidhash(
        sapisid: String,
        origin: String = "https://www.youtube.com"
    ) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let payload = "\(ts) \(sapisid) \(origin)"
#if canImport(CryptoKit)
        let digest = Insecure.SHA1.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
#else
        let hex = "dummy_hash" // Stub for Android
#endif
        return "SAPISIDHASH \(ts)_\(hex)"
    }
}

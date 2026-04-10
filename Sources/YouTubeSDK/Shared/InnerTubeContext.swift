//
//  InnerTubeContext.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

/// Responsible for building the JSON payload required for every InnerTube request.
public struct InnerTubeContext: Sendable {
    
    private let client: ClientConfig
    public let cookies: String?
    
    private let gl: String // Geo-Location (e.g., "US")
    private let hl: String // Host Language (e.g., "en")
    private let onBehalfOfUser: String?
    
    public init(
        client: ClientConfig,
        cookies: String? = nil,
        gl: String = "US",
        hl: String = "en",
        onBehalfOfUser: String? = nil
    ) {
        self.client = client
        self.cookies = cookies
        self.gl = gl
        self.hl = hl
        self.onBehalfOfUser = onBehalfOfUser?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Public Properties for Networking
    
    /// The API Key to append to the URL.
    public var apiKey: String {
        return client.apiKey
    }
    
    /// The headers required for the HTTP Request.
    public var headers: [String: String] {
        var defaultHeaders = [
            "User-Agent": client.userAgent,
            "Content-Type": "application/json",
            "X-YouTube-Client-Name": client.clientNameID,
            "X-YouTube-Client-Version": client.version
        ]
        
        // Inject Cookies if present
        if let cookies = cookies {
            defaultHeaders["Cookie"] = cookies
            
            // Authorization header is usually needed with cookies for some calls
            // We extract the SAPISID from the cookie to generate the SAPISIDHASH (we can add this later)
        }
        
        return defaultHeaders
    }
    
    /// The JSON body required for the HTTP Request.
    public var body: [String: Any] {
        var user: [String: Any] = [
            "lockedSafetyMode": false
        ]

        if let onBehalfOfUser, !onBehalfOfUser.isEmpty {
            user["onBehalfOfUser"] = onBehalfOfUser
        }

        return [
            "context": [
                "client": [
                    "clientName": client.name,
                    "clientVersion": client.version,
                    "gl": gl,
                    "hl": hl,
                    "timeZone": "UTC",
                    "utcOffsetMinutes": 0
                ],
                "user": user
            ]
        ]
    }
}

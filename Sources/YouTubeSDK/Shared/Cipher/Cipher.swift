//
//  Cipher.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 01/01/26.
//

import Foundation

actor Cipher {
    // We cache the script URL because it changes rarely
    static let shared = Cipher()
    private var cachedScriptURL: String?
    
    private let engine = DecipherEngine()
    private var isEngineReady: Bool = false
    
    /// Fetches the current player JS URL from the YouTube Watch Page
    func getCipherScriptURL(network: NetworkClient) async throws -> String {
        if let cached = cachedScriptURL { return cached }
        
        // 1. Fetch the raw HTML of a video page (any video works)
        // We use the Web Client because it always has the script reference
        let htmlData = try await network.fetchRawHTML("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        // Note: You might need to add a 'sendGET' method to NetworkClient that takes a full URL string
        
        guard let html = String(data: htmlData, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
        
        // 2. Regex to find the script path
        // Pattern: <script src="/s/player/nw123/player_ias.vflset/en_US/base.js">
        let pattern = #"/s/player/[a-zA-Z0-9]+/[a-zA-Z0-9_.]+/([a-zA-Z0-9_]{2,}/)?base\.js"#
        
        guard let range = html.range(of: pattern, options: .regularExpression) else {
            throw URLError(.resourceUnavailable)
        }
        
        let path = String(html[range])
        let fullURL = "https://www.youtube.com\(path)"
        
        self.cachedScriptURL = fullURL
        return fullURL
    }
    
    func decipher(url: String, signatureCipher: String, network: NetworkClient) async throws -> URL {
        if !isEngineReady {
            let scriptURL = try await getCipherScriptURL(network: network)
            print("Fetching Cipher Script: \(scriptURL)")
            
            // We need to fetch the raw JS text.
            // Note: Ensure NetworkClient allows GET requests to external URLs
            let scriptData = try await network.fetchRawHTML(scriptURL)
            guard let script = String(data: scriptData, encoding: .utf8) else {
                throw URLError(.cannotParseResponse)
            }
            
            try engine.loadCipherScript(script)
            isEngineReady = true
        }
        
        // 2. Parse the cipher string
        let cipherParams = parseCipher(signatureCipher)
        guard let signature = cipherParams["s"], let signatureParams = cipherParams["sp"] else {
            return URL(string: url)!
        }
        
        let decryptedSignature = try engine.decipher(signature: signature)
        
        // 3. Construct the final URL
        // Original URL + "&sig=DBCA" (or whatever 'sp' is, usually 'sig')
        var components = URLComponents(string: cipherParams["url"] ?? url)
        var queryItems = components?.queryItems ?? []
        queryItems.append(URLQueryItem(name: signatureParams, value: decryptedSignature))
        components?.queryItems = queryItems
        
        guard let finalURL = components?.url else { throw URLError(.badURL) }
        return finalURL
    }
}

extension Cipher {
    /// Breaks down the "signatureCipher" string into a dictionary
    func parseCipher(_ cipher: String) -> [String: String] {
        var params: [String: String] = [:]
        // It's URL encoded, so we separate by '&'
        for pair in cipher.components(separatedBy: "&") {
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                // Decode the values (they are percent-coded)
                let key = parts[0]
                let value = parts[1].removingPercentEncoding ?? parts[1]
                params[key] = value
            }
        }
        
        return params
    }
}

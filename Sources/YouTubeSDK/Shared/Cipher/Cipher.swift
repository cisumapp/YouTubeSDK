//
//  Cipher.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 01/01/26.
//

import Foundation

actor Cipher {
    // We cache the script URL and content because it changes rarely
    static let shared = Cipher()
    private var cachedScriptURL: String?
    private var cachedScriptContent: String?
    
    private let engine = DecipherEngine()
    private var isEngineReady: Bool = false
    
    /// Fetches the current player JS URL from the YouTube Watch Page
    func getCipherScriptURL(network: NetworkClient) async throws -> String {
        if let cached = cachedScriptURL { return cached }
        
        // 1. Fetch the raw HTML of a video page (any video works)
        // We use the Web Client because it always has the script reference
        let htmlData = try await network.fetchRawHTML("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        
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
        print("DECIPHER ENGINE: Discovered player script at \(fullURL)")
        return fullURL
    }

    private func ensureEngineReady(network: NetworkClient) async throws {
        if isEngineReady { return }

        let scriptURL = try await getCipherScriptURL(network: network)
        
        let script: String
        if let cached = cachedScriptContent {
            script = cached
        } else {
            print("DECIPHER ENGINE: Fetching script content from network...")
            let scriptData = try await network.fetchRawHTML(scriptURL)
            guard let content = String(data: scriptData, encoding: .utf8) else {
                throw URLError(.cannotParseResponse)
            }
            self.cachedScriptContent = content
            script = content
        }
        
        try engine.loadCipherScript(script)
        isEngineReady = true
    }
    
    func decipher(url: String, signatureCipher: String, network: NetworkClient) async throws -> URL {
        try await ensureEngineReady(network: network)
        
        // 1. Parse the cipher string
        let cipherParams = parseCipher(signatureCipher)
        let originalURLString = cipherParams["url"] ?? url
        
        // 2. Decipher Signature (s)
        var finalURLString = originalURLString
        if let signature = cipherParams["s"], let signatureParams = cipherParams["sp"] {
            let decryptedSignature = try engine.decipher(signature: signature)
            var components = URLComponents(string: finalURLString)
            var queryItems = components?.queryItems ?? []
            queryItems.append(URLQueryItem(name: signatureParams, value: decryptedSignature))
            components?.queryItems = queryItems
            finalURLString = components?.url?.absoluteString ?? finalURLString
        }
        
        // 3. Decipher 'n' parameter (throttling)
        do {
            return try await decipherN(url: finalURLString, network: network)
        } catch {
            print("DECIPHER ENGINE: DecipherN failed, resetting engine state: \(error)")
            isEngineReady = false // Force re-load on next attempt
            throw error
        }
    }

    func decipherN(url: String, network: NetworkClient) async throws -> URL {
        try await ensureEngineReady(network: network)

        var components = URLComponents(string: url)
        var queryItems = components?.queryItems ?? []
        
        if let index = queryItems.firstIndex(where: { $0.name == "n" }),
           let nValue = queryItems[index].value {
            let decipheredN = try engine.decipherN(nValue: nValue)
            queryItems[index].value = decipheredN
            components?.queryItems = queryItems
        }
        
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

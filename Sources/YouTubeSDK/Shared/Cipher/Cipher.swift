//
//  Cipher.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 01/01/26.
//
//  COMMENTED OUT: The decipher engine is not currently needed — all streams
//  return direct URLs with cipher=nil and no 'n' parameter.
//  SmartTubeIOS does not use a decipher engine.
//  Re-enable if YouTube re-introduces cipher-protected URLs.
//

/*
 import Foundation

 actor Cipher {
     static let shared = Cipher()
     private var cachedScriptURL: String?
     private var cachedScriptContent: String?
     private var cachedSignatureTimestamp: Int?

     private let engine = DecipherEngine()
     private var isEngineReady: Bool = false
     private var engineInitTask: Task<Void, Never>?

     var signatureTimestamp: Int? {
         cachedSignatureTimestamp
     }

     func getCipherScriptURL(network: NetworkClient) async throws -> String {
         if let cached = cachedScriptURL { return cached }

         let path: String

         // Approach 1: Try getting player ID from /iframe_api (YouTube.js approach)
         if let playerId = try? await getPlayerId(network: network) {
             path = "/s/player/\(playerId)/player_ias.vflset/en_US/base.js"
             print("DECIPHER ENGINE: Got player ID from iframe_api: \(playerId)")
         } else {
             // Approach 2: Scrape from watch page HTML
             let htmlData = try await network.fetchRawHTML("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
             guard let html = String(data: htmlData, encoding: .utf8) else { throw URLError(.cannotParseResponse) }

             let patterns = [
                 #"\/s\/player\/[a-zA-Z0-9]+\/[a-zA-Z0-9_.]+\/([a-zA-Z0-9_-]+\/)?base\.js"#,
                 #"\\\/s\\\/player\\\/[a-zA-Z0-9]+\\\/[a-zA-Z0-9_.]+\\\/([a-zA-Z0-9_-]+\\\/)?base\.js"#,
                 #"/s/player/[a-zA-Z0-9]+/[a-zA-Z0-9_.]+/([a-zA-Z0-9_-]+/)?base\.js"#,
             ]

             var foundPath: String?
             for pattern in patterns {
                 if let range = html.range(of: pattern, options: .regularExpression) {
                     var found = String(html[range])
                     found = found.replacingOccurrences(of: "\\/", with: "/")
                     foundPath = found
                     break
                 }
             }

             if foundPath == nil {
                 if let ytcfgRange = html.range(of: "ytcfg\\.set\\s*\\([^)]+", options: .regularExpression),
                    let jsonStart = html[ytcfgRange].range(of: "{"),
                    let jsonData = String(html[ytcfgRange][jsonStart.lowerBound...]).data(using: .utf8),
                    let ytcfg = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                    let playerURL = ytcfg["PLAYER_JS_URL"] as? String {
                     foundPath = playerURL
                 }
             }

             if let fp = foundPath {
                 path = fp
             } else {
                 print("DECIPHER ENGINE: WARNING - Failed to discover player script. Using fallback.")
                 path = "/s/player/2d01abf7/player_ias.vflset/en_US/base.js"
             }
         }

         let fullURL = path.hasPrefix("http") ? path : "https://www.youtube.com\(path)"
         self.cachedScriptURL = fullURL
         print("DECIPHER ENGINE: Discovered player script at \(fullURL)")
         return fullURL
     }

     private func getPlayerId(network: NetworkClient) async throws -> String {
         let data = try await network.fetchRawHTML("https://www.youtube.com/iframe_api")
         guard let js = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
         let pattern = #"player\\/([a-zA-Z0-9]+)\\/"#
         guard let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: js) else {
             throw URLError(.cannotParseResponse)
         }
         return String(js[range])
     }

     func ensureEngineReady(network: NetworkClient) async {
         if isEngineReady { return }

         if let existing = engineInitTask {
             return await existing.value
         }

         let task = Task { [network] in
             await self.initializeEngine(network: network)
         }
         engineInitTask = task
         await task.value
     }

     private func initializeEngine(network: NetworkClient) async {
         if isEngineReady { return }

         do {
             let scriptURL = try await getCipherScriptURL(network: network)
             let script: String
             if let cached = cachedScriptContent {
                 script = cached
             } else {
                 print("DECIPHER ENGINE: Fetching script content from network...")
                 let scriptData = try await network.fetchRawHTML(scriptURL)
                 guard let content = String(data: scriptData, encoding: .utf8) else {
                     print("DECIPHER ENGINE: Failed to decode script content")
                     return
                 }
                 self.cachedScriptContent = content
                 script = content
             }

             engine.loadCipherScript(script)
             cachedSignatureTimestamp = extractSignatureTimestamp(from: script)
             isEngineReady = true
         } catch {
             print("DECIPHER ENGINE: Failed to initialize engine: \(error)")
         }
     }

     func decipher(url: String, signatureCipher: String, network: NetworkClient) async -> URL? {
         await ensureEngineReady(network: network)

         let cipherParams = parseCipher(signatureCipher)
         let originalURLString = cipherParams["url"] ?? url

         if let sig = cipherParams["s"] {
             let sp = cipherParams["sp"] ?? "signature"
             let decryptedSignature = engine.decipher(signature: sig)
             print("DECIPHER FLOW: sig(\(sig.prefix(10))...) → (\(decryptedSignature.prefix(10))...) sp=\(sp)")
             var components = URLComponents(string: originalURLString)
             var queryItems = components?.queryItems ?? []
             queryItems.append(URLQueryItem(name: sp, value: decryptedSignature))
             components?.queryItems = queryItems
             return await decipherN(url: components?.url?.absoluteString ?? originalURLString, network: network)
         } else {
             print("DECIPHER FLOW: no 's' in cipher, going straight to decipherN")
             return await decipherN(url: originalURLString, network: network)
         }
     }

     func decipherN(url: String, network: NetworkClient) async -> URL? {
         await ensureEngineReady(network: network)

         var components = URLComponents(string: url)
         guard var queryItems = components?.queryItems else {
             print("DECIPHER FLOW: nil components for url=\(url.prefix(60))")
             return components?.url
         }

         if let idx = queryItems.firstIndex(where: { $0.name == "n" }), let nVal = queryItems[idx].value {
             let decipheredN = engine.decipherN(nValue: nVal)
             print("DECIPHER FLOW: n(\(nVal.prefix(10))...) → (\(decipheredN.prefix(10))...)")
             queryItems[idx].value = decipheredN
             components?.queryItems = queryItems
         } else {
             print("DECIPHER FLOW: no 'n' param in URL")
         }

         return components?.url
     }

 }

 extension Cipher {
     func parseCipher(_ cipher: String) -> [String: String] {
         var params: [String: String] = [:]
         for pair in cipher.components(separatedBy: "&") {
             let parts = pair.components(separatedBy: "=")
             if parts.count == 2 {
                 let key = parts[0]
                 let value = parts[1].removingPercentEncoding ?? parts[1]
                 params[key] = value
             }
         }
         return params
     }

     func extractSignatureTimestamp(from playerScript: String) -> Int? {
         let patterns = [
             #"signatureTimestamp['\":\s]+(\d+)"#,
             #"sts['\":\s]+(\d+)"#,
         ]
         for pattern in patterns {
             if let regex = try? NSRegularExpression(pattern: pattern),
                let match = regex.firstMatch(in: playerScript, range: NSRange(location: 0, length: playerScript.utf16.count)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: playerScript) {
                 let val = Int(playerScript[range])
                 if val != nil { print("DECIPHER ENGINE: signatureTimestamp = \(val!)") }
                 return val
             }
         }
         print("DECIPHER ENGINE: Could not extract signatureTimestamp")
         return nil
     }
 }
 */

import Foundation
import JavaScriptCore
import os.log

/// A unified resolver that solves YouTube's JavaScript-based challenges (n-parameter and signature cipher).
///
/// YouTube uses these challenges to throttle third-party clients and enforce bot detection.
/// This implementation uses the bundled yt-dlp EJS AST solver evaluated in `JSContext`,
/// which works on both iOS Simulator and real iOS/tvOS devices.
public actor YouTubeJSResolver {
    public static let shared = YouTubeJSResolver()

    private let log = Logger(subsystem: appSubsystem, category: "JSResolver")

    /// Memoisation cache: (playerID, challenge_type, scrambled_value) → solved_value.
    private var cache: [String: String] = [:]
    
    /// Cached player.js content mapped by playerID.
    private var playerJSCache: [String: String] = [:]

    /// Cached solver script components to avoid repeated disk/bundle access.
    private var cachedLibCode: String?
    private var cachedCoreCode: String?

    // MARK: - Public (n-parameter)

    /// Returns `url` with its `n` parameter (query or path segment) replaced by the descrambled value.
    /// Falls back to the original URL if descrambling is not possible.
    public func descrambleURL(_ url: URL, playerID: String?) async -> URL {
        guard let playerID, !playerID.isEmpty else { return url }
        guard let scrambled = extractNParam(from: url) else { return url }
        
        let cacheKey = "\(playerID):n:\(scrambled)"
        if let cached = cache[cacheKey] {
            return replacing(n: scrambled, with: cached, in: url)
        }
        
        guard let descrambled = try? await solveChallenge(scrambled, type: "n", playerID: playerID) else {
            log.error("n-descramble failed for \(playerID as NSString) — returning original URL (n=\(scrambled as NSString))")
            return url
        }
        
        cache[cacheKey] = descrambled
        log.notice("n-descramble OK (\(playerID as NSString)): \(scrambled as NSString) → \(descrambled as NSString)")
        return replacing(n: scrambled, with: descrambled, in: url)
    }
    
    /// Solves the n-challenge for a given playerID and scrambled value.
    public func solveN(playerID: String, n: String) async -> String? {
        let cacheKey = "\(playerID):n:\(n)"
        if let cached = cache[cacheKey] { return cached }
        
        if let solved = try? await solveChallenge(n, type: "n", playerID: playerID) {
            cache[cacheKey] = solved
            return solved
        }
        return nil
    }

    // MARK: - Public (Signature Cipher)

    /// Solves a signature cipher and returns the complete URL with the valid signature parameter.
    public func resolveSignatureCipher(playerID: String, cipher: String) async -> URL? {
        let params = parseCipherString(cipher)
        guard let originalURLString = params["url"],
              let scrambledSig = params["s"] else {
            return nil
        }
        
        let sigParam = params["sp"] ?? "signature"
        
        let cacheKey = "\(playerID):sig:\(scrambledSig)"
        let solvedSig: String
        if let cached = cache[cacheKey] {
            solvedSig = cached
        } else if let solved = try? await solveChallenge(scrambledSig, type: "sig", playerID: playerID) {
            cache[cacheKey] = solved
            solvedSig = solved
            log.notice("sig-decipher OK (\(playerID as NSString)): \(scrambledSig.prefix(10) as NSString)... → \(solvedSig.prefix(10) as NSString)...")
        } else {
            log.error("sig-decipher failed for \(playerID as NSString)")
            return nil
        }
        
        guard var comps = URLComponents(string: originalURLString) else { return nil }
        var queryItems = comps.queryItems ?? []
        queryItems.append(URLQueryItem(name: sigParam, value: solvedSig))
        comps.queryItems = queryItems
        
        return comps.url
    }

    // MARK: - URL helpers

    private func extractNParam(from url: URL) -> String? {
        // 1. Check query parameter
        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let nItem = comps.queryItems?.first(where: { $0.name == "n" }),
           let n = nItem.value, !n.isEmpty {
            return n
        }
        
        // 2. Check path component (HLS variants: .../n/SCRAMBLED/...)
        let parts = url.pathComponents
        let idx = parts.firstIndex(of: "n")
        if let idx, idx + 1 < parts.count {
            let n = parts[idx + 1]
            return n.isEmpty ? nil : n
        }
        return nil
    }

    private func replacing(n old: String, with new: String, in url: URL) -> URL {
        let original = url.absoluteString
        
        // Handle path segment replacement
        if original.contains("/n/\(old)/") {
            let replaced = original.replacingOccurrences(of: "/n/\(old)/", with: "/n/\(new)/")
            return URL(string: replaced) ?? url
        }
        
        // Handle query parameter replacement
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        if let idx = items.firstIndex(where: { $0.name == "n" && $0.value == old }) {
            items[idx].value = new
            comps.queryItems = items
            return comps.url ?? url
        }
        
        return url
    }

    private func parseCipherString(_ cipher: String) -> [String: String] {
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

    // MARK: - Core solving logic

    private func solveChallenge(_ scrambled: String, type: String, playerID: String) async throws -> String? {
        guard let playerJS = await ensurePlayerJS(playerID: playerID) else { return nil }
        let (libCode, coreCode) = try await getSolverScripts()

        return await Task.detached(priority: .userInitiated) { [scrambled, type, playerJS, libCode, coreCode] in
            // Delegate to static helper to avoid any implicit capture of 'self' (the actor).
            return Self.evaluateJSChallenge(
                scrambled: scrambled,
                type: type,
                playerJS: playerJS,
                libCode: libCode,
                coreCode: coreCode
            )
        }.value
    }

    /// Pure, non-isolated JS evaluator that works on a background thread.
    nonisolated private static func evaluateJSChallenge(
        scrambled: String,
        type: String,
        playerJS: String,
        libCode: String,
        coreCode: String
    ) -> String? {
        let context = JSContext()!
        var jsError: String?
        context.exceptionHandler = { _, e in jsError = e?.toString() }

        context.evaluateScript(libCode)
        context.evaluateScript("var meriyah = lib.meriyah; var astring = lib.astring;")
        context.evaluateScript(coreCode)
        context.setObject(playerJS, forKeyedSubscript: "playerJSContent" as NSString)

        context.setObject(scrambled, forKeyedSubscript: "scrambledValue" as NSString)
        context.setObject(type,      forKeyedSubscript: "challengeType"  as NSString)

        let result = context.evaluateScript("""
        (function() {
            try {
                var r = jsc({type:'player', player:playerJSContent,
                             requests:[{type:challengeType, challenges:[scrambledValue]}]});
                return (r && r.responses && r.responses[0] && r.responses[0].data)
                    ? r.responses[0].data[scrambledValue] : null;
            } catch(e) { return null; }
        })()
        """)

        if let err = jsError {
            print("❌ [JSResolver/JSC] exception: \(err)")
        }
        let solved = result?.toString()
        guard let s = solved, !s.isEmpty, s != "null", s != "undefined", s != scrambled else {
            return nil
        }
        return s
    }

    private func getSolverScripts() async throws -> (lib: String, core: String) {
        if let lib = cachedLibCode, let core = cachedCoreCode {
            return (lib, core)
        }

        guard let libURL  = Bundle.module.url(forResource: "yt.solver.lib.min",  withExtension: "js"),
              let coreURL = Bundle.module.url(forResource: "yt.solver.core.min", withExtension: "js"),
              let libCode  = try? String(contentsOf: libURL,  encoding: .utf8),
              let coreCode = try? String(contentsOf: coreURL, encoding: .utf8) else {
            throw APIError.decodingError("Solver scripts missing from bundle")
        }

        self.cachedLibCode = libCode
        self.cachedCoreCode = coreCode
        return (libCode, coreCode)
    }

    // MARK: - player.js management

    private func ensurePlayerJS(playerID: String) async -> String? {
        if let cached = playerJSCache[playerID] {
            return cached
        }
        
        let tempPath = NSTemporaryDirectory() + "yt_player_\(playerID).js"
        if let cached = try? String(contentsOfFile: tempPath, encoding: .utf8), !cached.isEmpty {
            playerJSCache[playerID] = cached
            return cached
        }
        
        guard let playerURL = URL(string: "https://www.youtube.com/s/player/\(playerID)/player_es6.vflset/en_US/base.js") else { return nil }
        
        do {
            log.notice("Downloading player.js (\(playerID as NSString))...")
            let (data, _) = try await URLSession.shared.data(from: playerURL)
            guard let js = String(data: data, encoding: .utf8) else { return nil }
            try? js.write(toFile: tempPath, atomically: true, encoding: .utf8)
            playerJSCache[playerID] = js
            log.notice("Downloaded player.js (\(playerID as NSString)) — \(data.count) bytes")
            return js
        } catch {
            log.error("Failed to download player.js (\(playerID as NSString)): \(error)")
            return nil
        }
    }
}

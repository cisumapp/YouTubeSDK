import Foundation
import JavaScriptCore
import os.log

/// A unified resolver that solves YouTube's JavaScript-based challenges (n-parameter and signature cipher).
///
/// ## Caching Architecture (AST-Once)
/// The EJS AST solver must parse a ~3MB player.js file. To avoid doing this on every track:
///
/// 1. **One-time parse**: On the first solve for a given playerID, JavaScriptCore parses
///    player.js once (~2-3 seconds). The EJS AST solver extracts the actual tiny
///    (~5KB) solver functions for `n` and `sig` and returns them as plain JS strings.
///
/// 2. **Solver extraction**: These extracted solver strings are cached per playerID.
///    Subsequent calls create a fresh JSContext (lightweight), evaluate only the 5KB
///    solver, and return the result in ~1ms with near-zero CPU.
///
/// 3. **In-process**: All work runs in JavaScriptCore, directly in the app's process.
///    This shares the app's background audio privileges and 2GB RAM budget, making it
///    immune to background jetsams that terminated WKWebView's WebContent process.
///
/// ## Safety
/// - `solveChallenge` dispatches to `Task.detached` so JSC work runs on a background thread.
/// - The actor serialises all cache mutations safely.
public actor YouTubeJSResolver {
    public static let shared = YouTubeJSResolver()

    private let log = Logger(subsystem: appSubsystem, category: "JSResolver")

    // MARK: - Result cache: (playerID, type, scrambled) → solved

    /// Final answer cache: avoids re-solving the same value twice.
    private var solvedCache: [String: String] = [:]

    // MARK: - player.js cache

    /// Raw player.js content, keyed by playerID.
    private var playerJSCache: [String: String] = [:]

    // MARK: - Extracted solver cache (the key optimisation)

    /// Per-playerID extracted solver source for n-parameter descrambling (~5KB JS function).
    private var nSolverSourceCache: [String: String] = [:]

    /// Per-playerID extracted solver source for signature deciphering (~5KB JS function).
    private var sigSolverSourceCache: [String: String] = [:]

    // MARK: - Bundled EJS lib/core cache

    private var cachedLibCode: String?
    private var cachedCoreCode: String?

    // MARK: - Public (n-parameter)

    /// Returns `url` with its `n` parameter replaced by the descrambled value.
    /// Falls back to the original URL if descrambling is not possible.
    public func descrambleURL(_ url: URL, playerID: String?) async -> URL {
        guard let playerID, !playerID.isEmpty else { return url }
        guard let scrambled = extractNParam(from: url) else { return url }

        let cacheKey = "\(playerID):n:\(scrambled)"
        if let cached = solvedCache[cacheKey] {
            return replacing(n: scrambled, with: cached, in: url)
        }

        guard let descrambled = try? await solveChallenge(scrambled, type: "n", playerID: playerID) else {
            log.error("n-descramble failed for \(playerID as NSString) — returning original URL (n=\(scrambled as NSString))")
            return url
        }

        solvedCache[cacheKey] = descrambled
        log.notice("n-descramble OK (\(playerID as NSString)): \(scrambled as NSString) → \(descrambled as NSString)")
        return replacing(n: scrambled, with: descrambled, in: url)
    }

    /// Solves the n-challenge for a given playerID and scrambled value.
    public func solveN(playerID: String, n: String) async -> String? {
        let cacheKey = "\(playerID):n:\(n)"
        if let cached = solvedCache[cacheKey] { return cached }

        if let solved = try? await solveChallenge(n, type: "n", playerID: playerID) {
            solvedCache[cacheKey] = solved
            return solved
        }
        return nil
    }

    // MARK: - Public (Signature Cipher)

    /// Solves a signature cipher and returns the complete URL with the valid signature parameter.
    public func resolveSignatureCipher(playerID: String, cipher: String) async -> URL? {
        let params = parseCipherString(cipher)
        guard let originalURLString = params["url"],
              let scrambledSig = params["s"]
        else {
            return nil
        }

        let sigParam = params["sp"] ?? "signature"

        let cacheKey = "\(playerID):sig:\(scrambledSig)"
        let solvedSig: String
        if let cached = solvedCache[cacheKey] {
            solvedSig = cached
        } else if let solved = try? await solveChallenge(scrambledSig, type: "sig", playerID: playerID) {
            solvedCache[cacheKey] = solved
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
           let n = nItem.value, !n.isEmpty
        {
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
        // --- Fast path: use pre-extracted solver if available ---
        if let solverSource = cachedSolverSource(type: type, playerID: playerID) {
            let result = await Task.detached(priority: .userInitiated) {
                Self.evaluateExtractedSolver(
                    solverSource: solverSource,
                    scrambled: scrambled,
                    type: type
                )
            }.value
            if let r = result { return r }
            // Fall through to full parse if extracted solver fails
            log.notice("[\(type)] extracted solver returned nil — falling back to full AST parse")
        }

        // --- Slow path: full AST parse to extract solver, then cache it ---
        guard let playerJS = await ensurePlayerJS(playerID: playerID) else { return nil }
        let (libCode, coreCode) = try await getSolverScripts()

        let capturedPlayerID = playerID
        let capturedType = type

        let (solved, extractedSolver) = await Task.detached(priority: .userInitiated) { [scrambled, playerJS, libCode, coreCode] in
            Self.evaluateJSChallengeExtractingSolver(
                scrambled: scrambled,
                type: capturedType,
                playerJS: playerJS,
                libCode: libCode,
                coreCode: coreCode
            )
        }.value

        // Cache the extracted tiny solver for future calls (the key optimisation)
        if let solver = extractedSolver {
            storeSolverSource(solver, type: type, playerID: playerID)
            log.notice("[\(type)] cached extracted solver for playerID=\(playerID as NSString) (\(solver.count) chars)")
        }

        return solved
    }

    private func cachedSolverSource(type: String, playerID: String) -> String? {
        switch type {
        case "n": nSolverSourceCache[playerID]
        case "sig": sigSolverSourceCache[playerID]
        default: nil
        }
    }

    private func storeSolverSource(_ source: String, type: String, playerID: String) {
        switch type {
        case "n": nSolverSourceCache[playerID] = source
        case "sig": sigSolverSourceCache[playerID] = source
        default: break
        }
    }

    // MARK: - Fast path: evaluate cached 5KB solver

    /// Evaluates a pre-extracted ~5KB solver function in a fresh JSContext.
    /// This takes ~1ms and uses near-zero CPU — no 3MB AST parse needed.
    private nonisolated static func evaluateExtractedSolver(
        solverSource: String,
        scrambled: String,
        type: String
    ) -> String? {
        let ctx = JSContext()!
        var jsError: String?
        ctx.exceptionHandler = { _, e in jsError = e?.toString() }

        // Install minimal polyfills
        ctx.evaluateScript("var window = this; var globalThis = this; var self = this;")

        // Evaluate the extracted solver function and call it
        let script: String
        switch type {
        case "n":
            // The extracted solver is typically: function(a) { ... return a; }
            // We wrap it so we can call it
            script = """
            (function() {
                try {
                    var solverFn = \(solverSource);
                    if (typeof solverFn !== 'function') return null;
                    var result = solverFn(\(jsonStringLiteral(scrambled)));
                    return (typeof result === 'string' && result.length > 0 && result !== \(jsonStringLiteral(scrambled))) ? result : null;
                } catch(e) { return null; }
            })()
            """
        case "sig":
            // Signature solver is typically: function(a) { ... return a.join(''); }
            script = """
            (function() {
                try {
                    var solverFn = \(solverSource);
                    if (typeof solverFn !== 'function') return null;
                    var a = \(jsonStringLiteral(scrambled)).split('');
                    var result = solverFn(a);
                    if (typeof result === 'string' && result.length > 0) return result;
                    // Some sig solvers mutate the array and return nothing; join it
                    if (Array.isArray(a) && a.length > 0) return a.join('');
                    return null;
                } catch(e) { return null; }
            })()
            """
        default:
            return nil
        }

        let result = ctx.evaluateScript(script)
        if let err = jsError {
            print("❌ [JSResolver/fast] exception: \(err)")
        }
        let solved = result?.toString()
        guard let s = solved, !s.isEmpty, s != "null", s != "undefined", s != scrambled else {
            return nil
        }
        return s
    }

    // MARK: - Slow path: full AST parse + solver extraction

    /// Runs the full EJS AST parse of player.js once.
    /// Returns (solved value, extracted solver source).
    /// The extracted solver source is cached so future calls bypass the 3MB parse.
    private nonisolated static func evaluateJSChallengeExtractingSolver(
        scrambled: String,
        type: String,
        playerJS: String,
        libCode: String,
        coreCode: String
    ) -> (solved: String?, extractedSolver: String?) {
        let context = JSContext()!
        var jsError: String?
        context.exceptionHandler = { _, e in jsError = e?.toString() }

        // Minimal polyfills
        context.evaluateScript("var window = this; var globalThis = this; var self = this;")
        context.evaluateScript(libCode)
        context.evaluateScript("var meriyah = lib.meriyah; var astring = lib.astring;")
        context.evaluateScript(coreCode)
        context.setObject(playerJS, forKeyedSubscript: "playerJSContent" as NSString)
        context.setObject(scrambled, forKeyedSubscript: "scrambledValue" as NSString)
        context.setObject(type, forKeyedSubscript: "challengeType" as NSString)

        // Run the solver and simultaneously extract the solver function source
        // The EJS solver (jsc) returns solver function as part of its result
        let script = """
        (function() {
            try {
                var r = jsc({type:'player', player:playerJSContent,
                             requests:[{type:challengeType, challenges:[scrambledValue]}]});
                if (!r || !r.responses || !r.responses[0] || !r.responses[0].data) {
                    return {solved: null, solverSource: null};
                }
                var solved = r.responses[0].data[scrambledValue] || null;
                // Extract the solver function source if the result includes it
                var solverSource = null;
                if (r.responses[0].solver) {
                    try { solverSource = r.responses[0].solver.toString(); } catch(e) {}
                } else if (r.responses[0].solverSource) {
                    solverSource = r.responses[0].solverSource;
                }
                return {solved: solved, solverSource: solverSource};
            } catch(e) { return {solved: null, solverSource: null}; }
        })()
        """

        let resultObj = context.evaluateScript(script)

        if let err = jsError {
            print("❌ [JSResolver/slow] exception: \(err)")
        }

        let solved: String? = {
            let v = resultObj?.objectForKeyedSubscript("solved")?.toString()
            guard let s = v, !s.isEmpty, s != "null", s != "undefined", s != scrambled else { return nil }
            return s
        }()

        let extractedSolver: String? = {
            let v = resultObj?.objectForKeyedSubscript("solverSource")?.toString()
            guard let s = v, !s.isEmpty, s != "null", s != "undefined" else { return nil }
            return s
        }()

        // If the EJS solver didn't expose the solver source directly, try to extract it
        // from player.js using regex patterns (yt-dlp approach as fallback)
        let finalSolver = extractedSolver ?? extractSolverSourceFromPlayerJS(
            playerJS: playerJS,
            type: type
        )

        return (solved, finalSolver)
    }

    /// Extracts the raw solver function source from player.js using yt-dlp-compatible
    /// regex patterns. This is the fallback when the EJS solver doesn't expose it directly.
    private nonisolated static func extractSolverSourceFromPlayerJS(
        playerJS: String,
        type: String
    ) -> String? {
        switch type {
        case "n":
            // yt-dlp n-solver extraction patterns
            let nPatterns = [
                #"\.get\("n"\)\)&&\(b=([a-zA-Z0-9$]{2,3})\[(\d+)\]\([a-zA-Z]\)"#,
                #",([a-zA-Z0-9$]{2,3})\[(\d+)\]=function\(([a-zA-Z])\)\{"#,
                #"([a-zA-Z0-9$]{2,3})\.length\|\|([a-zA-Z0-9$]{2,3})\[0\]\(([a-zA-Z0-9$])"#,
                #"\.get\("n"\)\)&&\(([a-zA-Z0-9$]+)=([a-zA-Z0-9$]+)\[(\d+)\]"#,
            ]
            for pattern in nPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: playerJS, range: NSRange(playerJS.startIndex..., in: playerJS))
                {
                    // Try to extract the function body around the match
                    if let range = Range(match.range, in: playerJS) {
                        let matchStr = String(playerJS[range])
                        if let fn = extractNearbyFunction(in: playerJS, near: range.lowerBound) {
                            return fn
                        }
                        _ = matchStr // suppress warning
                    }
                }
            }
            return nil

        case "sig":
            // Signature cipher solver extraction
            let sigPatterns = [
                #"function\([a-zA-Z]\)\{[a-zA-Z]=[a-zA-Z]\.split\(""\);[A-Za-z0-9$]{2,3}\."#,
                #"([a-zA-Z0-9$]{2})\=function\([a-zA-Z]\)\{[a-zA-Z]=[a-zA-Z]\.split\(\"\"\)"#,
            ]
            for pattern in sigPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: playerJS, range: NSRange(playerJS.startIndex..., in: playerJS)),
                   let range = Range(match.range, in: playerJS)
                {
                    if let fn = extractNearbyFunction(in: playerJS, near: range.lowerBound) {
                        return fn
                    }
                }
            }
            return nil

        default:
            return nil
        }
    }

    /// Finds and extracts a complete JS function starting near the given position in player.js.
    private nonisolated static func extractNearbyFunction(in js: String, near start: String.Index) -> String? {
        // Search backward for 'function(' or '=>' within 200 chars of the match
        let searchStart = js.index(start, offsetBy: -min(200, js.distance(from: js.startIndex, to: start)))
        let searchEnd = js.index(start, offsetBy: min(500, js.distance(from: start, to: js.endIndex)))
        let region = js[searchStart ..< searchEnd]

        // Find 'function' keyword
        guard let fnRange = region.range(of: "function(") ?? region.range(of: "function (") else { return nil }
        let fnStart = fnRange.lowerBound

        // Find the opening brace
        guard let braceStart = region[fnStart...].firstIndex(of: "{") else { return nil }

        // Extract balanced braces
        var depth = 0
        var i = braceStart
        while i < region.endIndex {
            let ch = region[i]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(region[fnStart ... i])
                }
            }
            i = region.index(after: i)
        }
        return nil
    }

    // MARK: - Solver scripts

    private func getSolverScripts() async throws -> (lib: String, core: String) {
        if let lib = cachedLibCode, let core = cachedCoreCode {
            return (lib, core)
        }

        guard let libURL = Bundle.module.url(forResource: "yt.solver.lib.min", withExtension: "js"),
              let coreURL = Bundle.module.url(forResource: "yt.solver.core.min", withExtension: "js"),
              let libCode = try? String(contentsOf: libURL, encoding: .utf8),
              let coreCode = try? String(contentsOf: coreURL, encoding: .utf8)
        else {
            throw APIError.decodingError("Solver scripts missing from bundle")
        }

        cachedLibCode = libCode
        cachedCoreCode = coreCode
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

    // MARK: - Helpers

    private nonisolated static func jsonStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

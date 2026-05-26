#if canImport(WebKit)
import WebKit
import JavaScriptCore
import os


private let extractLog = Logger(subsystem: appSubsystem, category: "WebViewHLS")

/// Extracts a YouTube HLS manifest URL by loading the YouTube watch page in a hidden
/// WKWebView and intercepting the YouTube JavaScript player's internal `youtubei/v1/player`
/// network call.
///
/// **Why this works:**
/// YouTube generates HLS manifest URLs with `spc=` (proof-of-context) tokens only when the
/// request originates from a real browser JavaScript execution context. The `spc=` token is
/// computed by the YouTube player JS and makes HLS segment URLs work without `rqh=1` CDN
/// restrictions. Raw InnerTube API calls (even with Bearer auth) cannot generate `spc=` because
/// they lack the JavaScript execution context that YouTube's server verifies.
///
/// By running YouTube's JS player in WKWebView, the player computes `spc=` and includes it in
/// its internal `youtubei/v1/player` call. We intercept that response using JavaScript
/// XHR/fetch hooks and forward the `hlsManifestUrl` to Swift via `WKScriptMessageHandler`.
///
/// This approach works on both iOS Simulator and real device without any external tools.
@MainActor
public final class YouTubeWebViewHLSExtractor: NSObject {

    public static let shared = YouTubeWebViewHLSExtractor()

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var timeoutTask: Task<Void, Never>?
    /// After `extractHLSURL` completes, holds the n-challenge mapping solved in-JS.
    /// `nil` when the URL had no `/n/` or the solver wasn't available.
    public private(set) var extractedNSolver: (unsolved: String, solved: String)?

    // MARK: - Public API

    /// Loads the YouTube watch page for `videoId` in a hidden WKWebView, waits for the
    /// YouTube JS player to make its internal `youtubei/v1/player` call, and returns
    /// the `hlsManifestUrl` from that response.
    ///
    /// - Parameter videoId: The YouTube video ID.
    /// - Parameter timeoutSeconds: How long to wait before giving up. Default 40 s.
    /// - Returns: The HLS master manifest URL (may include `spc=`), or `nil` on failure/timeout.
    public func extractHLSURL(videoId: String, timeoutSeconds: Double = 40) async -> URL? {
        // Cancel any pending extraction before starting a new one.
        finish(url: nil)
        extractedNSolver = nil

        extractLog.notice("⚠️ [webView] starting HLS extraction for \(videoId as NSString)")

        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            self.continuation = cont

            let contentController = WKUserContentController()
            contentController.add(self, name: "hlsExtractor")

            // Inject the EJS AST-based n-challenge solver (lib + core) BEFORE
            // our interceptor so that `jsc` is available when solveNFromPlayerJS runs.
            if let solverScripts = Self.ejsSolverUserScripts() {
                for script in solverScripts {
                    contentController.addUserScript(script)
                }
            }

            // Inject the interceptor BEFORE the document loads so it can hook into
            // XMLHttpRequest and fetch before YouTube's player JS initialises.
            contentController.addUserScript(WKUserScript(
                source: Self.interceptorJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))

            let config = WKWebViewConfiguration()
            config.userContentController = contentController
            // Allow programmatic video playback (no user gesture required) so that
            // after we get the hlsManifestUrl we can call video.play() to let the YouTube
            // player seed googlevideo.com session cookies into the WKWebView cookie store.
            config.mediaTypesRequiringUserActionForPlayback = []
            // Use .default() so existing WKWebView cookies from earlier loads are reused.
            config.websiteDataStore = .default()

            // Non-zero off-screen frame so the compositor renders the video element,
            // which is required for programmatic playback on iOS.
            let wv = WKWebView(frame: CGRect(x: -1, y: -1, width: 1, height: 1), configuration: config)
            wv.navigationDelegate = self
            self.webView = wv

            // Use a desktop Safari UA so YouTube serves its full player (which provides
            // hlsManifestUrl in the youtubei/v1/player API response). After capturing the URL
            // we solve the n-challenge by calling _yt_player.Etr(url) via evaluateJavaScript —
            // that is YouTube's own n-solver function, bound globally as _yt_player.Etr.
            wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
                "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
                "Version/17.5 Safari/605.1.15"

            guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else {
                extractLog.error("❌ [webView] invalid videoId: \(videoId as NSString)")
                cont.resume(returning: Optional<URL>.none)
                self.continuation = nil
                return
            }

            var request = URLRequest(url: url)
            // Accept-Language: YouTube uses this to pick the page language; using en-US
            // avoids consent-wall redirects seen in some locales.
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            wv.load(request)

            // Timeout safety net.
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard let self, self.continuation != nil else { return }
                extractLog.notice("⚠️ [webView] timed out for \(videoId as NSString)")
                self.finish(url: Optional<URL>.none)
            }
        }
    }

    // MARK: - EJS Solver Scripts

    /// Loads the yt-dlp EJS AST-based n-challenge solver scripts from the app bundle
    /// and returns them as ordered WKUserScript instances ready for injection.
    ///
    /// Injection order matters:
    ///   1. lib.min.js  — defines `var lib = {meriyah, astring}` (JS AST parser + code-gen)
    ///   2. bridge       — exposes `meriyah` and `astring` as top-level globals
    ///   3. core.min.js — defines `var jsc = (function(e,n){...})(meriyah, astring)` (solver)
    private static func ejsSolverUserScripts() -> [WKUserScript]? {
        guard let libURL  = Bundle.module.url(forResource: "yt.solver.lib.min",  withExtension: "js"),
              let coreURL = Bundle.module.url(forResource: "yt.solver.core.min", withExtension: "js"),
              let libCode  = try? String(contentsOf: libURL,  encoding: .utf8),
              let coreCode = try? String(contentsOf: coreURL, encoding: .utf8) else {
            extractLog.warning("⚠️ [webView] EJS solver scripts not found in bundle")
            return nil
        }
        let bridgeCode = "var meriyah = (typeof lib !== 'undefined' && lib.meriyah) || undefined; " +
                         "var astring = (typeof lib !== 'undefined' && lib.astring) || undefined;"
        return [
            WKUserScript(source: libCode,    injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: bridgeCode, injectionTime: .atDocumentStart, forMainFrameOnly: true),
            WKUserScript(source: coreCode,   injectionTime: .atDocumentStart, forMainFrameOnly: true),
        ]
    }

    // MARK: - JavaScript Interceptor

    /// Injected at document-start. Intercepts the YouTube player's internal API call,
    /// extracts `hlsManifestUrl`, and solves the HLS-specific n-challenge before sending to Swift.
    ///
    /// N-challenge strategy:
    ///   1. `tryExtractHLS` fires when the YouTube player API response arrives (~2.5 s).
    ///   2. An async IIFE immediately fetches the HLS master manifest (same URL, same origin,
    ///      usually CORS-allowed from youtube.com → manifest.googlevideo.com) to find the
    ///      per-quality variant URL which contains `/n/{HLS_unsolved}/` in its path.
    ///   3. It then fetches the player JS (loaded in the page; usually a cache hit in WKWebView)
    ///      and uses yt-dlp-style regex patterns to locate the n-solver function stored in an
    ///      array inside the minified player code.
    ///   4. The solver is extracted via bracket-balanced parsing (handles commas in fn bodies),
    ///      evaluated, and called with the HLS unsolved n-value to produce the solved n.
    ///   5. The mapping (unsolvedHLS → solvedHLS) is sent to Swift so `YTHLSProxyLoader` can
    ///      rewrite all `/n/unsolved/` occurrences in the M3U8 playlist text before AVPlayer
    ///      reads it — making CDN segment requests return HTTP 200 instead of 403.
    ///   6. A 9-second fallback timer fires if the async chain fails or times out, sending
    ///      whatever state is available (nil if player JS extraction failed).
    private static let interceptorJS: String = #"""
    (function() {
        'use strict';

        var sentFinalURL = false;
        // Set to true as soon as tryExtractHLS starts its async resolution,
        // to suppress xhrManifest/fetchManifest fallbacks from firing.
        var hlsExtractionStarted = false;

        function sendHLSURL(hlsUrl, poToken, source, unsolvedN, solvedN, playerID) {
            if (sentFinalURL) return;
            sentFinalURL = true;
            window.webkit.messageHandlers.hlsExtractor.postMessage(
                JSON.stringify({
                    hlsManifestUrl: hlsUrl,
                    poToken:        poToken   || null,
                    source:         source    || 'unknown',
                    unsolvedN:      unsolvedN || null,
                    solvedN:        solvedN   || null,
                    playerID:       playerID  || null
                })
            );
        }

        function isManifestVariantURL(url) {
            var s = url ? url.toString() : '';
            return s.indexOf('manifest.googlevideo.com') !== -1 &&
                   (s.indexOf('hls_variant') !== -1 || s.indexOf('hls_manifest') !== -1);
        }

        function isPlayerURL(url) {
            return url && url.toString().indexOf('youtubei/v1/player') !== -1;
        }

        // ── N-solver extraction from player JS ────────────────────────────────────────
        // Extracts the function at `arrIdx` from the array `arrName` in `jsText`.
        // Uses bracket-balanced parsing so commas inside function bodies don't split incorrectly.
        function extractFnFromJSArray(jsText, arrName, arrIdx) {
            var safe = arrName.replace(/[$]/g, '\\$');
            var decl = new RegExp('var\\s+' + safe + '\\s*=\\s*\\[');
            var di   = jsText.search(decl);
            if (di < 0) return null;

            var ob = jsText.indexOf('[', di);
            if (ob < 0) return null;

            var depth = 1, i = ob + 1, eStart = ob + 1, eIdx = 0;
            while (i < jsText.length && depth > 0) {
                var ch = jsText[i];
                if (ch === '[' || ch === '{' || ch === '(') {
                    depth++;
                } else if (ch === ']' || ch === '}' || ch === ')') {
                    depth--;
                    if (depth === 0) {
                        if (eIdx === arrIdx) return jsText.slice(eStart, i).trim();
                        break;
                    }
                } else if ((ch === '"' || ch === "'" || ch === '`') && depth === 1) {
                    var q = ch; i++;
                    while (i < jsText.length && jsText[i] !== q) {
                        if (jsText[i] === '\\') i++;
                        i++;
                    }
                } else if (ch === ',' && depth === 1) {
                    if (eIdx === arrIdx) return jsText.slice(eStart, i).trim();
                    eIdx++;
                    eStart = i + 1;
                }
                i++;
            }
            return null;
        }

        // Downloads the main player JS and uses the bundled EJS AST-based solver (jsc)
        // to solve `unsolvedN`. Returns the solved string, or null on failure.
        // `jsc` is defined by the solver WKUserScripts injected before this script.
        async function solveNFromPlayerJS(unsolvedN) {
            try {
                // jsc must be available from the EJS solver scripts injected at document-start
                if (typeof jsc !== 'function') return null;

                // Locate the IAS player script to extract the player ID
                var playerSrc = null;
                var scripts = document.querySelectorAll('script[src]');
                for (var si = 0; si < scripts.length; si++) {
                    if (scripts[si].src && scripts[si].src.indexOf('player_ias') > -1) {
                        playerSrc = scripts[si].src;
                        break;
                    }
                }
                if (!playerSrc) return null;

                // Build the main-variant URL (player_es6) from the player ID.
                // yt-dlp forces the 'main' variant (player_es6.vflset/en_US/base.js)
                // because only that variant contains the n-solver function.
                var pidMatch = playerSrc.match(/\/player\/([a-f0-9]+)\//);
                if (!pidMatch) return null;
                var mainUrl = 'https://www.youtube.com/s/player/' + pidMatch[1] +
                              '/player_es6.vflset/en_US/base.js';

                // Fetch with cache:default so WKWebView serves from cache if available,
                // or fetches from network (~2.5 MB) on first call.
                var jsResp = await origFetch.call(window, mainUrl, {cache: 'default'});
                if (!jsResp.ok) return null;
                var jsText = await jsResp.text();

                // Run the EJS AST-based solver. This parses the player JS, locates the
                // n-solver function structurally, calls it, and returns the solved value.
                var solverInput = {
                    type: 'player',
                    player: jsText,
                    requests: [{type: 'n', challenges: [unsolvedN]}]
                };
                var result = jsc(solverInput);
                if (result && result.type === 'result' &&
                    result.responses && result.responses.length > 0) {
                    var resp = result.responses[0];
                    if (resp.type === 'result' && resp.data) {
                        var solved = resp.data[unsolvedN];
                        return (typeof solved === 'string' && solved !== unsolvedN) ? solved : null;
                    }
                }
                return null;
            } catch(e) {
                return null;
            }
        }

        // ── Main extraction ───────────────────────────────────────────────────────────
        function tryExtractHLS(responseData, requestBodyStr) {
            if (sentFinalURL || hlsExtractionStarted) return false;
            try {
                var obj = (typeof responseData === 'string') ?
                          JSON.parse(responseData) : responseData;
                if (!obj || !obj.streamingData || !obj.streamingData.hlsManifestUrl)
                    return false;

                var hlsUrl  = obj.streamingData.hlsManifestUrl;
                var poToken = null;
                try {
                    if (requestBodyStr) {
                        var rq = JSON.parse(requestBodyStr);
                        if (rq && rq.serviceIntegrityDimensions &&
                            rq.serviceIntegrityDimensions.poToken)
                            poToken = rq.serviceIntegrityDimensions.poToken;
                    }
                } catch(e) {}

                hlsExtractionStarted = true;

                // Extract player ID from multiple sources (in priority order).
                // Sent to Swift so it can run the EJS solver via Node.js as a fallback.
                var playerID = null;
                try {
                    // Method 1: script[src] with any /player/ path segment
                    var piScripts = document.querySelectorAll('script[src]');
                    for (var psi = 0; psi < piScripts.length; psi++) {
                        var pSrc = piScripts[psi].src || piScripts[psi].getAttribute('src') || '';
                        if (pSrc.indexOf('/player/') > -1) {
                            var pidM = pSrc.match(/\/player\/([a-f0-9]+)\//);
                            if (pidM) { playerID = pidM[1]; break; }
                        }
                    }
                    // Method 2: ytcfg.get('PLAYER_JS_URL')
                    if (!playerID && window.ytcfg && typeof window.ytcfg.get === 'function') {
                        var pjsUrl = window.ytcfg.get('PLAYER_JS_URL') ||
                                     window.ytcfg.get('jsUrl') || '';
                        if (pjsUrl) {
                            var pm2 = pjsUrl.match(/\/player\/([a-f0-9]+)\//);
                            if (pm2) playerID = pm2[1];
                        }
                    }
                    // Method 3: Scan page HTML for the IAS player URL pattern (always present)
                    if (!playerID) {
                        var pageHtml = document.documentElement.innerHTML || '';
                        var pm3 = pageHtml.match(/\/s\/player\/([a-f0-9]{8})\/player_ias/);
                        if (pm3) playerID = pm3[1];
                    }
                } catch(e) {}

                // Async phase: fetch master manifest → extract HLS n-value → solve it
                (async function() {
                    var hlsN = null, solvedN = null;

                    // Fallback timer: if async chain takes >20 s, send whatever we have.
                    var fallbackTimer = setTimeout(function() {
                        sendHLSURL(hlsUrl, poToken, 'apiResponse', hlsN, solvedN, playerID);
                    }, 20000);

                    try {
                        // Step 1: Fetch the HLS master manifest to find a per-quality
                        // playlist URL containing /n/{hlsN}/ in the path.
                        var mResp = await origFetch.call(window, hlsUrl, {credentials: 'include'});
                        var mText = await mResp.text();
                        // Per-quality playlist URLs embed the HLS n-value as a path segment
                        var nm = mText.match(/\/n\/([A-Za-z0-9_-]{10,})\//);
                        if (nm) hlsN = nm[1];
                    } catch(e) {}

                    try {
                        // Step 2: Try in-JS EJS solver (only works if jsc is defined).
                        if (hlsN && typeof jsc === 'function') solvedN = await solveNFromPlayerJS(hlsN);
                    } catch(e) {}

                    clearTimeout(fallbackTimer);
                    // Include playerID so Swift can run the Node.js solver as fallback.
                    sendHLSURL(hlsUrl, poToken, 'apiResponse', hlsN, solvedN, playerID);
                })();

                return true;
            } catch(e) {}
            return false;
        }

        // ── video.src hook (iOS/native-HLS mode fallback) ────────────────────────────
        var mediaProto  = HTMLMediaElement.prototype;
        var origSrcDesc = Object.getOwnPropertyDescriptor(mediaProto, 'src');
        if (origSrcDesc && origSrcDesc.set) {
            Object.defineProperty(mediaProto, 'src', {
                set: function(url) {
                    if (url && typeof url === 'string' && isManifestVariantURL(url))
                        sendHLSURL(url, null, 'videoSrc', null, null);
                    return origSrcDesc.set.call(this, url);
                },
                get: origSrcDesc.get,
                configurable: true
            });
        }

        // ── XHR hook ──────────────────────────────────────────────────────────────────
        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;

        XMLHttpRequest.prototype.open = function(method, url) {
            var urlStr = url ? url.toString() : '';
            this.__isPlayerReq   = isPlayerURL(urlStr);
            this.__isManifestReq = isManifestVariantURL(urlStr);
            if (this.__isManifestReq) this.__manifestUrl = urlStr;
            return origOpen.apply(this, arguments);
        };

        XMLHttpRequest.prototype.send = function(body) {
            // xhrManifest fallback — only fires if player API never responded
            if (this.__isManifestReq && this.__manifestUrl && !hlsExtractionStarted)
                sendHLSURL(this.__manifestUrl, null, 'xhrManifest', null, null);
            if (this.__isPlayerReq) {
                var capturedBody = (typeof body === 'string') ? body : null;
                this.addEventListener('load', function() {
                    tryExtractHLS(this.responseText, capturedBody);
                });
            }
            return origSend.apply(this, arguments);
        };

        // ── fetch hook ────────────────────────────────────────────────────────────────
        var origFetch = window.fetch;
        window.fetch = function(input, init) {
            var url = (typeof input === 'string') ? input :
                      (input && (input.url || input.href)) || '';
            var bodyStr = null;
            try {
                if (isPlayerURL(url) && init && init.body)
                    bodyStr = (typeof init.body === 'string') ? init.body : null;
            } catch(e) {}

            var promise = origFetch.apply(this, arguments);
            if (isManifestVariantURL(url)) {
                // fetchManifest fallback — only fires if player API never responded
                if (!hlsExtractionStarted)
                    sendHLSURL(url, null, 'fetchManifest', null, null);
            } else if (isPlayerURL(url)) {
                var capturedBody = bodyStr;
                promise.then(function(response) {
                    return response.clone().text().then(function(text) {
                        tryExtractHLS(text, capturedBody);
                    });
                }).catch(function() {});
            }
            return promise;
        };

        // ── DOMContentLoaded fallback ─────────────────────────────────────────────────
        document.addEventListener('DOMContentLoaded', function() {
            try {
                if (window.ytInitialPlayerResponse)
                    tryExtractHLS(window.ytInitialPlayerResponse, null);
            } catch(e) {}
        });
    })();
    """#

    // MARK: - Private helpers

    private func finishWithURL(_ url: URL, poToken: String?) {
        if let pot = poToken, !pot.isEmpty {
            let potURL = URL(string: url.absoluteString.appending("/pot/\(pot)")) ?? url
            finish(url: potURL)
        } else {
            finish(url: url)
        }
    }

    private func finish(url: URL?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        // Capture and immediately nil the continuation so the cancelled timeout
        // task (which wakes after CancellationError swallowed by try?) cannot
        // double-resume it when it calls finish(url: nil).
        let pendingContinuation = continuation
        continuation = nil

        guard let url, let pendingContinuation else {
            // Either nil URL (timeout/error) or already resumed — just clean up.
            pendingContinuation?.resume(returning: Optional<URL>.none)
            webView?.navigationDelegate = nil
            webView?.stopLoading()
            webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            webView = nil
            return
        }

        extractLog.notice("✅ [webView] hlsManifestUrl extracted url=\(String(url.absoluteString.prefix(200)) as NSString)")

        // Sync youtube.com session cookies from WKWebView's httpCookieStore into
        // HTTPCookieStorage.shared NOW (page-load cookies are already set by the time
        // the player makes its /player call — no need to wait for video playback).
        // The proxy loader will attach these cookies to googlevideo.com segment requests
        // so the CDN can validate the /bui/ token against VISITOR_INFO1_LIVE.
        let capturedURL = url
        Task { @MainActor [weak self] in
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    let gvCount = cookies.filter { $0.domain.contains("googlevideo") }.count
                    let names = cookies.map { "\($0.name)@\($0.domain)" }.joined(separator: " ")
                    extractLog.notice("⚠️ [webView] syncing \(cookies.count) cookies (\(gvCount) googlevideo): \(names as NSString)")
                    for cookie in cookies {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }
                    cont.resume()
                }
            }
            guard let self else { return }
            self.webView?.navigationDelegate = nil
            self.webView?.stopLoading()
            self.webView?.configuration.userContentController.removeAllScriptMessageHandlers()
            self.webView = nil
            pendingContinuation.resume(returning: capturedURL)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension YouTubeWebViewHLSExtractor: WKScriptMessageHandler {
    public func userContentController(_ userContentController: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard message.name == "hlsExtractor" else { return }

        // Message is now a JSON object: { hlsManifestUrl, poToken, source, unsolvedN, solvedN }
        var hlsURLString: String?
        var poToken: String?
        var urlSource = "unknown"
        var unsolvedNValue: String? = nil
        var solvedNValue: String? = nil
        var playerIDValue: String? = nil

        if let body = message.body as? String {
            // Try to parse as JSON first (new format)
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                hlsURLString = json["hlsManifestUrl"] as? String
                poToken = json["poToken"] as? String
                urlSource = (json["source"] as? String) ?? "unknown"
                unsolvedNValue = json["unsolvedN"] as? String
                solvedNValue = json["solvedN"] as? String
                playerIDValue = json["playerID"] as? String
            } else {
                // Fallback: raw URL string (old format)
                hlsURLString = body
            }
        }

        guard let urlString = hlsURLString,
              let url = URL(string: urlString),
              urlString.contains("googlevideo.com") || urlString.contains("manifest") else {
            return
        }

        extractLog.notice("⚠️ [webView] URL captured source=\(urlSource as NSString)")

        // If the JS interceptor already solved the n-challenge, use it directly.
        if let u = unsolvedNValue, let s = solvedNValue, u != s {
            extractedNSolver = (unsolved: u, solved: s)
            extractLog.notice("✅ [webView] n-challenge solved in JS: \(u as NSString) → \(s as NSString)")
            finishWithURL(url, poToken: poToken)
            return
        }

        // JS solver was not available — try solving on the Swift side via JSC.
        if let playerID = playerIDValue, let unsolvedN = unsolvedNValue, !unsolvedN.isEmpty {
                extractLog.notice("⚠️ [webView] JS solver unavailable; launching JSC solver for playerID=\(playerID as NSString) n=\(unsolvedN as NSString)")
            let capturedURL    = url
            let capturedPoToken = poToken
            Task { @MainActor [weak self] in
                guard let self else { return }
                let solved = await YouTubeJSResolver.shared.solveN(playerID: playerID, n: unsolvedN)
                if let s = solved, !s.isEmpty, s != unsolvedN {
                    self.extractedNSolver = (unsolved: unsolvedN, solved: s)
                    extractLog.notice("✅ [webView] n solved via JSC: \(unsolvedN as NSString) → \(s as NSString)")
                } else {
                    self.extractedNSolver = nil
                    extractLog.notice("⚠️ [webView] JSC solver returned nil/same for n=\(unsolvedN as NSString)")
                }
                self.finishWithURL(capturedURL, poToken: capturedPoToken)
            }
            return
        }

        // No n-challenge found or no player ID available.
        if let u = unsolvedNValue {
            extractedNSolver = nil
            extractLog.notice("⚠️ [webView] n NOT solved (no playerID available): unsolvedN=\(u as NSString)")
        } else {
            extractedNSolver = nil
            extractLog.notice("⚠️ [webView] no n-challenge found in HLS manifest")
        }
        finishWithURL(url, poToken: poToken)
    }
}

// MARK: - WKNavigationDelegate

extension YouTubeWebViewHLSExtractor: WKNavigationDelegate {

    public func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        extractLog.error("❌ [webView] navigation failed: \(error.localizedDescription as NSString)")
        finish(url: Optional<URL>.none)
    }

    public func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        extractLog.error("❌ [webView] provisional navigation failed: \(error.localizedDescription as NSString)")
        finish(url: Optional<URL>.none)
    }
}

#endif // canImport(WebKit)

/// YTHLSProxyLoader.swift
/// Proxies HLS playlist requests through URLSession so the correct
/// User-Agent (desktop Safari) is sent to manifest.googlevideo.com.
/// AVURLAssetHTTPHeaderFieldsKey does not reliably propagate User-Agent through
/// CoreMedia's internal HLS stack — this resource loader fills that gap.

#if canImport(WebKit)
import AVFoundation
import Foundation
import os.log

private let proxyScheme = "ytwebhls"
private let proxyLog = Logger(subsystem: "com.void.smarttube.app", category: "HLSProxy")

// MARK: - URL scheme helpers

public extension URL {
    /// Converts an https:// URL to ytwebhls:// for routing through the proxy.
    var proxyURL: URL? {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = proxyScheme
        return c.url
    }
    /// Converts a ytwebhls:// URL back to https:// for the actual network request.
    var realURL: URL? {
        guard scheme == proxyScheme,
              var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        return c.url
    }
}

// MARK: - YTHLSProxyLoader

/// `AVAssetResourceLoaderDelegate` that forwards HLS playlist requests through
/// `URLSession.shared` with a desktop-Safari User-Agent header.
public final class YTHLSProxyLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let ua: String
    /// When non-nil, the proxy rewrites all `/n/{unsolved}/` occurrences to `/n/{solved}/`
    /// in HLS playlist text before serving it to AVPlayer. This makes segment URLs carry
    /// the solved n-challenge so the video CDN accepts them (HTTP 200 instead of 403).
    let nSolver: (unsolved: String, solved: String)?
    private let lock = NSLock()
    private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    public init(ua: String, nSolver: (unsolved: String, solved: String)? = nil) {
        self.ua = ua
        self.nSolver = nSolver
    }

    // MARK: AVAssetResourceLoaderDelegate

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let proxyURL = loadingRequest.request.url,
              let realURL   = proxyURL.realURL else {
            return false
        }

        // Strategy: 
        // 1. For Playlists (.m3u8): Download manually, rewrite, and serve data.
        // 2. For Segments: Allow AVPlayer to load them natively via https://.
        // This matches SmartTubeIOS's proven strategy and avoids binary corruption.
        
        let isPlaylist = realURL.pathExtension.lowercased() == "m3u8" || realURL.lastPathComponent.lowercased() == "index.m3u8"
        
        if !isPlaylist {
            // Do NOT handle segments here. They should have been kept as https:// in the manifest.
            // If they reached here with ytwebhls://, something is wrong with the manifest rewriting.
            proxyLog.error("[HLSProxy] Unexpected segment request in proxy: \(realURL.lastPathComponent as NSString)")
            return false
        }

        var request = URLRequest(url: realURL, timeoutInterval: 30)
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let host = realURL.host, host.contains("googlevideo.com") {
            request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        }
        
        // Sync cookies from shared storage
        if let host = realURL.host, host.contains("googlevideo.com"),
           let ytCookies = HTTPCookieStorage.shared.cookies(for: URL(string: "https://www.youtube.com")!),
           !ytCookies.isEmpty {
            let cookieHeader = ytCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let key = ObjectIdentifier(loadingRequest)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.activeTasks.removeValue(forKey: key)
                self.lock.unlock()
            }

            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }

            guard let httpResp = response as? HTTPURLResponse, let data else {
                loadingRequest.finishLoading(with: NSError(domain: "YTHLSProxy", code: -1))
                return
            }

            var responseData = data
            if let text = String(data: data, encoding: .utf8) {
                let rewritten = self.rewritePlaylist(text, baseURL: realURL)
                responseData = rewritten.data(using: .utf8) ?? data
            }

            if let infoReq = loadingRequest.contentInformationRequest {
                infoReq.contentType = "public.m3u-playlist"
                infoReq.contentLength = Int64(responseData.count)
                infoReq.isByteRangeAccessSupported = false
            }

            loadingRequest.dataRequest?.respond(with: responseData)
            loadingRequest.finishLoading()
        }

        lock.lock()
        activeTasks[key] = task
        lock.unlock()
        task.resume()
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        lock.lock()
        let task = activeTasks.removeValue(forKey: key)
        lock.unlock()
        task?.cancel()
    }

    // MARK: Playlist rewriting

    private func rewritePlaylist(_ m3u8: String, baseURL: URL) -> String {
        var text = m3u8
        
        // Step 1: Replace unsolved n-challenge
        if let (unsolved, solved) = nSolver, !unsolved.isEmpty, unsolved != solved {
            let oldN = "/n/\(unsolved)/"
            let newN = "/n/\(solved)/"
            text = text.replacingOccurrences(of: oldN, with: newN)
        }

        // Step 1.5: Synthesize missing #EXTINF tags (only for variant playlists)
        if !text.contains("#EXTINF") && !text.contains("#EXT-X-STREAM-INF") {
            let rawLines = text.components(separatedBy: "\n")
            var fixedLines: [String] = []
            var maxDurationSecs: Double = 4.0

            let ws = CharacterSet(charactersIn: " \t\r\n")
            for rawLine in rawLines {
                let trimmed = rawLine.trimmingCharacters(in: ws)
                if trimmed == "#EXTM3U" {
                    fixedLines.append(rawLine)
                    fixedLines.append("__TARGETDURATION_PLACEHOLDER__")
                    fixedLines.append("#EXT-X-VERSION:3")
                    fixedLines.append("#EXT-X-MEDIA-SEQUENCE:0")
                } else if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    fixedLines.append(rawLine)
                } else {
                    var durationSecs: Double = 4.0
                    if let lenStart = trimmed.range(of: "/len/") {
                        let after = trimmed[lenStart.upperBound...]
                        if let lenEnd = after.firstIndex(of: "/") {
                            if let ms = Double(after[..<lenEnd]), ms > 0 {
                                durationSecs = ms / 1000.0
                            }
                        }
                    }
                    maxDurationSecs = max(maxDurationSecs, durationSecs)
                    fixedLines.append("#EXTINF:\(String(format: "%.6f", durationSecs)),")
                    fixedLines.append(rawLine)
                }
            }

            let targetDurationTag = "#EXT-X-TARGETDURATION:\(Int(ceil(maxDurationSecs)))"
            text = fixedLines.map { $0 == "__TARGETDURATION_PLACEHOLDER__" ? targetDurationTag : $0 }.joined(separator: "\n")
        }

        // Step 2: Rewrite Sub-Playlist URLs to our proxy scheme
        // IMPORTANT: Only proxy the master and quality-level playlists.
        // Segments should stay as https:// so AVPlayer loads them natively.
        let pattern = "https://(manifest\\.googlevideo\\.com/api/manifest/hls_playlist/)"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "ytwebhls://$1")
        }
        
        return text
    }
}

extension YTHLSProxyLoader {
    
    /// Creates an AVPlayerItem for the given HLS manifest URL, proxying it through
    /// this loader if it requires n-parameter descrambling.
    @MainActor
    public static func makePlayerItem(for url: URL, nSolver: (unsolved: String, solved: String)? = nil) -> AVPlayerItem {
        let ua = InnerTubeClients.WebSafari.userAgent
        let headers: [String: String] = [
            "User-Agent": ua,
            "Referer": "https://www.youtube.com/",
            "Origin": "https://www.youtube.com"
        ]
        
        let proxy = YTHLSProxyLoader(ua: ua, nSolver: nSolver)
        
        // Convert to ytwebhls:// to trigger the resource loader delegate
        let proxyURLString = url.absoluteString.replacingOccurrences(of: "https://", with: "ytwebhls://")
        guard let proxyURL = URL(string: proxyURLString) else {
            return AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]))
        }
        
        let asset = AVURLAsset(url: proxyURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        asset.resourceLoader.setDelegate(proxy, queue: .main)
        
        // Cache the proxy loader on the asset so it isn't deallocated
        objc_setAssociatedObject(asset, &proxyLoaderKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        
        return AVPlayerItem(asset: asset)
    }
}

@MainActor private var proxyLoaderKey: UInt8 = 0
#endif

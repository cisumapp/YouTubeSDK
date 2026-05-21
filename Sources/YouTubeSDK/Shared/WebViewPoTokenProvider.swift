//
//  WebViewPoTokenProvider.swift
//  YouTubeSDK
//
//  A Proof-of-Origin token provider that runs completely on-device
//  using an off-screen WKWebView to satisfy YouTube BotGuard checks.
//

import Foundation
import WebKit

/// A PoToken provider that extracts tokens natively on-device using a headless WKWebView.
public final class WebViewPoTokenProvider: NSObject, PoTokenProvider, WKScriptMessageHandler, @unchecked Sendable {
    
    private var activeContinuations: [String: [CheckedContinuation<String, Error>]] = [:]
    private var webViews: [String: WKWebView] = [:]
    
    public override init() {
        super.init()
    }
    
    public func token(for videoId: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.startExtraction(videoId: videoId, continuation: continuation)
            }
        }
    }
    
    @MainActor
    private func startExtraction(videoId: String, continuation: CheckedContinuation<String, Error>) {
        if var conts = activeContinuations[videoId] {
            conts.append(continuation)
            activeContinuations[videoId] = conts
            return
        }
        
        activeContinuations[videoId] = [continuation]
        
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        
        let js = """
        (function() {
            const originalFetch = window.fetch;
            window.fetch = async function() {
                const url = arguments[0];
                const config = arguments[1];
                
                if (typeof url === 'string' && url.includes('/youtubei/v1/player') && config && config.body) {
                    try {
                        const body = JSON.parse(config.body);
                        if (body.serviceIntegrityDimensions && body.serviceIntegrityDimensions.poToken) {
                            const poToken = body.serviceIntegrityDimensions.poToken;
                            window.webkit.messageHandlers.poTokenHandler.postMessage({ videoId: "\(videoId)", poToken: poToken });
                        }
                    } catch (e) { }
                }
                return originalFetch.apply(this, arguments);
            };
            
            const originalSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.send = function(body) {
                if (this._url && this._url.includes('/youtubei/v1/player') && body) {
                    try {
                        const parsed = JSON.parse(body);
                        if (parsed.serviceIntegrityDimensions && parsed.serviceIntegrityDimensions.poToken) {
                            const poToken = parsed.serviceIntegrityDimensions.poToken;
                            window.webkit.messageHandlers.poTokenHandler.postMessage({ videoId: "\(videoId)", poToken: poToken });
                        }
                    } catch (e) { }
                }
                return originalSend.apply(this, arguments);
            };
            
            const originalOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
                this._url = url;
                return originalOpen.apply(this, arguments);
            };
            
            // Try to auto-play or click after a short delay
            setTimeout(() => {
                const player = document.querySelector('#movie_player') || document.querySelector('.html5-video-player');
                if (player) {
                    player.click();
                }
            }, 1000);
        })();
        """
        
        let script = WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        userContentController.addUserScript(script)
        userContentController.add(self, name: "poTokenHandler")
        config.userContentController = userContentController
        
        config.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        
        let webView = WKWebView(frame: .zero, configuration: config)
        // Optionally attach to a view hierarchy or just retain it
        self.webViews[videoId] = webView
        
        let url = URL(string: "https://www.youtube.com/embed/\(videoId)")!
        webView.load(URLRequest(url: url))
        
        // Timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            if let conts = self.activeContinuations[videoId] {
                for cont in conts {
                    cont.resume(throwing: NSError(domain: "YouTubeSDK", code: 3, userInfo: [NSLocalizedDescriptionKey: "Timeout waiting for poToken from WebView"]))
                }
                self.activeContinuations.removeValue(forKey: videoId)
                self.webViews.removeValue(forKey: videoId)
            }
        }
    }
    
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        DispatchQueue.main.async {
            guard message.name == "poTokenHandler",
                  let body = message.body as? [String: Any],
                  let videoId = body["videoId"] as? String,
                  let poToken = body["poToken"] as? String else {
                return
            }
            
            if let conts = self.activeContinuations[videoId] {
                for cont in conts {
                    cont.resume(returning: poToken)
                }
                self.activeContinuations.removeValue(forKey: videoId)
                self.webViews.removeValue(forKey: videoId)
            }
        }
    }
}

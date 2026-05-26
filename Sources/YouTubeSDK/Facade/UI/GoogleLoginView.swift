//
//  GoogleLoginView.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 30/12/25.
//

import SwiftUI
import WebKit

/// Example usage:
/// In SwiftUI
///.sheet(isPresented: $showLogin) {
///    GoogleLoginView { cookies in
///        // 1. Save the session
///        YouTubeOAuthClient.saveCookies(cookies)
///
///        // 2. Refresh your services
///        yourService.login()
///
///        showLogin = false
///    }
///}

#if os(iOS) || os(macOS)

public struct GoogleLoginView: View {
    
    public var onLoginSuccess: (String) -> Void
    
    public init(onLoginSuccess: @escaping (String) -> Void) {
        self.onLoginSuccess = onLoginSuccess
    }
    
    public var body: some View {
        WebViewWrapper(onCookiesFound: onLoginSuccess)
            .ignoresSafeArea()
    }
}

// MARK: - Cross Platform Wrapper

#if os(macOS)
// macOS Implementation
struct WebViewWrapper: NSViewRepresentable {
    var onCookiesFound: (String) -> Void
    
    func makeNSView(context: Context) -> WKWebView {
        return SharedWebViewLogic.makeWebView(context: context)
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> SharedWebViewLogic.Coordinator {
        SharedWebViewLogic.Coordinator(onCookiesFound: onCookiesFound)
    }
}
#else
// iOS Implementation
struct WebViewWrapper: UIViewRepresentable {
    var onCookiesFound: (String) -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        return SharedWebViewLogic.makeWebView(context: context)
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> SharedWebViewLogic.Coordinator {
        SharedWebViewLogic.Coordinator(onCookiesFound: onCookiesFound)
    }
}
#endif

// MARK: - Shared Logic (To avoid code duplication)

struct SharedWebViewLogic {
    
    @MainActor static func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Essential: Non-persistent store avoids conflicts with Safari/System
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        
        let webView = WKWebView(frame: .zero, configuration: config)
        
        // We use the coordinator from the specific platform wrapper
        #if os(macOS)
        webView.navigationDelegate = context.coordinator
        #else
        webView.navigationDelegate = context.coordinator
        #endif
        
        // Load Google Login (Service=YouTube ensures we get the right cookies)
        if let url = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&passive=true&continue=https://www.youtube.com") {
            webView.load(URLRequest(url: url))
        }
        
        return webView
    }
    
    // The Coordinator handles the cookie extraction logic
    class Coordinator: NSObject, WKNavigationDelegate {
        var onCookiesFound: (String) -> Void
        
        init(onCookiesFound: @escaping (String) -> Void) {
            self.onCookiesFound = onCookiesFound
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                
                // We verify login by looking for the "SAPISID" authentication cookie
                let hasSession = cookies.contains { $0.name == "SAPISID" }
                
                if hasSession {
                    // Combine into "key=value; key2=value2" string
                    let cookieString = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    
                    print("✅ [GoogleLoginView] Login Successful!")
                    self.onCookiesFound(cookieString)
                }
            }
        }
    }
}

// Helper typealias to make 'Context' work in Shared Logic
#if os(macOS)
typealias Context = NSViewRepresentableContext<WebViewWrapper>
#else
typealias Context = UIViewRepresentableContext<WebViewWrapper>
#endif

#endif

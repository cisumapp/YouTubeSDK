//
//  YouTube.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

/// The central entry point for the YouTubeSDK.
/// Use this manager to access Main YouTube, Music, Charts, and Auth functionalities.
@MainActor
public final class YouTube {
    
    /// Shared singleton instance for ease of use.
    public static let shared = YouTube()
    
    /// The current session cookies. Setting this will update all child clients.
    public var cookies: String? {
        didSet {
            updateClients()
        }
    }
    
    /// Main YouTube Client (Videos, Search, Browsing)
    public private(set) var main: YouTubeClient
    
    /// YouTube Music Client (Discovery, Artist/Album/Playlist, Library)
    public private(set) var music: YouTubeMusicClient
    
    /// YouTube Charts Client (Top Songs, Videos, Artists)
    public private(set) var charts: YouTubeChartsClient
    
    /// OAuth and Session Management Client
    public private(set) var oauth: YouTubeOAuthClient
    
    public init(cookies: String? = nil) {
        self.cookies = cookies ?? YouTubeOAuthClient.loadCookies()
        
        // Initialize clients with initial cookies
        self.main = YouTubeClient(cookies: self.cookies)
        self.music = YouTubeMusicClient(cookies: self.cookies)
        self.charts = YouTubeChartsClient() // Charts usually doesn't need auth, but can be configured
        self.oauth = YouTubeOAuthClient()
    }
    
    /// Re-initializes clients with updated session information.
    private func updateClients() {
        self.main = YouTubeClient(cookies: cookies)
        self.music = YouTubeMusicClient(cookies: cookies)
        // Charts and OAuth might not strictly need re-init depending on implementation, 
        // but for safety we ensure they have the latest context if applicable.
    }
}

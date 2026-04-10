//
//  Constants.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

public struct YouTubeSDKConstants {
    public struct URLS {
        public static let googleSearchBaseURL = "https://www.google.com"
        public static let youtubeBaseURL = "https://www.youtube.com"
        public static let youtubeMusicBaseURL = "https://music.youtube.com"
        public static let youtubeSuggestions = "https://suggestqueries-clients6.youtube.com"
        public static let youtubeUpload = "https://upload.youtube.com"
        
        public struct API {
            /// Generic Base URL
            public static let baseURL = "https://youtubei.googleapis.com"
            
            /// Generic Production URLs
            public static let youtubeInnerTubeURL = "https://www.youtube.com/youtubei"
            public static let youtubeMusicInnerTubeURL = "https://music.youtube.com/youtubei"
            public static let youtubeChartsInnerTubeURL = "https://charts.youtube.com/youtubei"

            /// Suggestions URLs
            public static let youtubeSuggestionsURL = "https://suggestqueries-clients6.youtube.com/complete"
            
            /// Random InnerTube API URLs
            public static let googleapisInnerTubeURL = "https://youtubei.googleapis.com/youtubei"
            public static let stagingURL = "https://green-youtubei.sandbox.googleapis.com/youtubei"
            public static let releaseURL = "https://release-youtubei.sandbox.googleapis.com/youtubei"
            public static let testURL = "https://test-youtubei.sandbox.googleapis.com/youtubei"
            public static let camiURL = "https://cami-youtubei.sandbox.googleapis.com/youtubei"
            public static let uytfeURL = "https://uytfe.sandbox.googleapis.com/youtubei"
        }
    }
    
    public struct InternalKeys {
        public struct Renderers {
            public static let video = "videoRenderer"
            public static let gridVideo = "gridVideoRenderer"
            public static let compactVideo = "compactVideoRenderer"
            public static let videoWithContext = "videoWithContextRenderer"
            public static let reelItem = "reelItemRenderer"
            public static let richItem = "richItemRenderer"
            public static let itemSection = "itemSectionRenderer"
            public static let shelf = "shelfRenderer"
            public static let musicVideo = "musicVideoRenderer"
            public static let musicResponsiveListItem = "musicResponsiveListItemRenderer"
            public static let playlistVideo = "playlistVideoRenderer"
            public static let channel = "channelRenderer"
            public static let playlist = "playlistRenderer"
            public static let musicShelf = "musicShelfRenderer"
            public static let musicCarouselShelf = "musicCarouselShelfRenderer"
        }
        
        public struct BrowseIDs {
            // Main YouTube
            public static let home = "FEwhat_to_watch"
            public static let trending = "FEtrending"
            
            // YouTube Music
            public struct Music {
                public static let home = "FEmusic_home"
                public static let explore = "FEmusic_explore"
                public static let charts = "FEmusic_charts"
                public static let newReleases = "FEmusic_new_releases"
                public static let moods = "FEmusic_moods_and_genres"
                public static let library = "FEmusic_library"
                public static let libraryLanding = "FEmusic_library_landing"
                public static let likedPlaylists = "FEmusic_liked_playlists"
                public static let libraryCorpusTrackArtists = "FEmusic_library_corpus_track_artists"
                public static let libraryCorpusArtists = "FEmusic_library_corpus_artists"
                public static let libraryAlbums = "FEmusic_library_albums"
                public static let librarySongs = "FEmusic_library_songs"
                public static let history = "FEmusic_history"
                public static let likedMusic = "VLLM"
                public static let likedVideos = "FEmusic_liked_videos"
            }
        }
    }
}

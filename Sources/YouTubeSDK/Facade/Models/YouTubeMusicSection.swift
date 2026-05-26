//
//  YouTubeMusicSection.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//

import Foundation

public struct YouTubeMusicSection: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let items: [YouTubeMusicItem]
    
    init?(from data: [String: Any]) {
        // Extract Title
        if let header = data["header"] as? [String: Any],
           let titleRun = (header["musicCarouselShelfBasicHeaderRenderer"] ?? header["musicShelfHeaderRenderer"]) as? [String: Any],
           let titleText = (titleRun["title"] as? [String: Any])?["runs"] as? [[String: Any]],
           let title = titleText.first?["text"] as? String {
            self.title = title
        } else {
            self.title = ""
        }
        
        // Extract Contents
        guard let contents = data["contents"] as? [[String: Any]] else { return nil }
        
        self.items = contents.compactMap { itemDict in
            // Check for Song
            if let songData = itemDict["musicResponsiveListItemRenderer"] as? [String: Any] {
                if let song = YouTubeMusicSong(from: songData) { return .song(song) }
            }
            
            // Check for Album/Playlist (Two Row Item)
            if let boxData = itemDict["musicTwoRowItemRenderer"] as? [String: Any] {
                // Heuristic: Nav endpoint tells us what it is
                let nav = boxData["navigationEndpoint"] as? [String: Any]
                let browse = nav?["browseEndpoint"] as? [String: Any]
                
                // FIX: Break down the nested casting so Swift knows each level is a Dictionary
                let supportedConfigs = browse?["browseEndpointContextSupportedConfigs"] as? [String: Any]
                let musicConfig = supportedConfigs?["browseEndpointContextMusicConfig"] as? [String: Any]
                let pageType = musicConfig?["pageType"] as? String
                
                if pageType == "MUSIC_PAGE_TYPE_ALBUM" {
                    if let album = YouTubeMusicAlbum(from: boxData) { return .album(album) }
                } else if pageType == "MUSIC_PAGE_TYPE_PLAYLIST" {
                    if let playlist = YouTubeMusicPlaylist(from: boxData) { return .playlist(playlist) }
                } else if pageType == "MUSIC_PAGE_TYPE_ARTIST" {
                    if let artist = YouTubeMusicArtist(from: boxData) { return .artist(artist) }
                }
            }
            return nil
        }
    }
}

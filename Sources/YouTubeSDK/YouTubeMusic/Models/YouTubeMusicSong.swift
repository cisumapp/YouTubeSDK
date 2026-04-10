//
//  YouTubeMusicSong.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

public struct YouTubeMusicSong: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let artists: [String]
    public let album: String?
    public let duration: TimeInterval?
    public let thumbnailURL: URL?
    public let videoId: String
    public let isExplicit: Bool
    
    // Helper for UI
    public var artistsDisplay: String { artists.joined(separator: ", ") }

    /// Robust Manual Initializer.
    /// Extracts data from a "musicResponsiveListItemRenderer" dictionary.
    init?(from data: [String: Any]) {
        // 1. ID Extraction (Try videoId, fallback to navigationEndpoint)
        var extractedId: String?
        
        if let vid = data["videoId"] as? String {
            extractedId = vid
        } else if let playlistItem = data["playlistItemData"] as? [String: Any],
                  let vid = playlistItem["videoId"] as? String {
            extractedId = vid
        } else if let endpoint = data["navigationEndpoint"] as? [String: Any],
                  let watch = endpoint["watchEndpoint"] as? [String: Any],
                  let vid = watch["videoId"] as? String {
            extractedId = vid
        }
        
        guard let finalId = extractedId else { return nil }
        self.id = finalId
        self.videoId = finalId
        
        // 2. Title (Flex Column 0)
        if let columns = data["flexColumns"] as? [[String: Any]],
           let firstCol = columns.first,
           let textParams = firstCol["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let textData = textParams["text"] as? [String: Any],
           let runs = textData["runs"] as? [[String: Any]],
           let title = runs.first?["text"] as? String {
            self.title = title
        } else {
            self.title = "Unknown Title"
        }
        
        // 3. Metadata (Flex Column 1: Artist, Album, Duration)
        var foundArtists: [String] = []
        var foundAlbum: String?
        var foundDuration: TimeInterval?
        
        if let columns = data["flexColumns"] as? [[String: Any]], columns.count > 1 {
            let secondCol = columns[1]
            if let textParams = secondCol["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
               let textData = textParams["text"] as? [String: Any],
               let runs = textData["runs"] as? [[String: Any]] {
                
                // Iterate through runs to categorize them
                // Kaset logic: Look for navigationEndpoint to identify Artist/Album
                for run in runs {
                    if let text = run["text"] as? String {
                        if let endpoint = run["navigationEndpoint"] as? [String: Any],
                           let browse = endpoint["browseEndpoint"] as? [String: Any],
                           let pageType = browse["browseEndpointContextSupportedConfigs"] as? [String: Any] {
                             
                             // Check type (Artist vs Album)
                             let config = pageType["browseEndpointContextMusicConfig"] as? [String: Any]
                             let type = config?["pageType"] as? String
                             
                             if type == "MUSIC_PAGE_TYPE_ARTIST" {
                                 foundArtists.append(text)
                             } else if type == "MUSIC_PAGE_TYPE_ALBUM" {
                                 foundAlbum = text
                             }
                        } else {
                            // If it's a timestamp (e.g. "3:45"), parse it
                            if text.contains(":") {
                                foundDuration = Self.parseDuration(text)
                            }
                        }
                    }
                }
            }
        }
        self.artists = foundArtists
        self.album = foundAlbum
        self.duration = foundDuration
        
        // 4. Thumbnail
        if let thumbContainer = data["thumbnail"] as? [String: Any],
           let musicThumb = thumbContainer["musicThumbnailRenderer"] as? [String: Any],
           let image = musicThumb["thumbnail"] as? [String: Any],
           let thumbnails = image["thumbnails"] as? [[String: Any]],
           let last = thumbnails.last,
           let urlString = last["url"] as? String {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }
        
        // 5. Explicit Badge
        // assume false, then prove true if found the badge.
        var explicitBadgeFound = false
        
        if let badges = data["badges"] as? [[String: Any]] {
            for badge in badges {
                if let renderer = badge["musicInlineBadgeRenderer"] as? [String: Any],
                   let icon = renderer["icon"] as? [String: Any],
                   let type = icon["iconType"] as? String,
                   type == "MUSIC_EXPLICIT_BADGE" {
                    explicitBadgeFound = true
                    break
                }
            }
        }
        
        self.isExplicit = explicitBadgeFound
    }

    /// Parser for `playlistPanelVideoRenderer` payloads returned by `next` and `music/get_queue`.
    init?(fromPlaylistPanelRenderer data: [String: Any]) {
        var extractedId: String?

        if let vid = data["videoId"] as? String {
            extractedId = vid
        } else if let endpoint = data["navigationEndpoint"] as? [String: Any],
                  let watch = endpoint["watchEndpoint"] as? [String: Any],
                  let vid = watch["videoId"] as? String {
            extractedId = vid
        }

        guard let finalId = extractedId else { return nil }
        self.id = finalId
        self.videoId = finalId

        if let titleData = data["title"] as? [String: Any],
           let simple = titleData["simpleText"] as? String,
           !simple.isEmpty {
            self.title = simple
        } else if let titleData = data["title"] as? [String: Any],
                  let runs = titleData["runs"] as? [[String: Any]],
                  let firstTitle = runs.first?["text"] as? String,
                  !firstTitle.isEmpty {
            self.title = firstTitle
        } else {
            self.title = "Unknown Title"
        }

        var foundArtists: [String] = []
        var foundAlbum: String?
        var foundDuration: TimeInterval?

        let bylineRuns: [[String: Any]] =
            ((data["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]) ??
            ((data["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []

        for run in bylineRuns {
            guard let text = run["text"] as? String else { continue }

            if let endpoint = run["navigationEndpoint"] as? [String: Any],
               let browse = endpoint["browseEndpoint"] as? [String: Any],
               let supportedConfigs = browse["browseEndpointContextSupportedConfigs"] as? [String: Any],
               let musicConfig = supportedConfigs["browseEndpointContextMusicConfig"] as? [String: Any],
               let pageType = musicConfig["pageType"] as? String {
                if pageType == "MUSIC_PAGE_TYPE_ARTIST" {
                    foundArtists.append(text)
                } else if pageType == "MUSIC_PAGE_TYPE_ALBUM", foundAlbum == nil {
                    foundAlbum = text
                }
                continue
            }

            if foundDuration == nil, text.contains(":"), let parsedDuration = Self.parseDuration(text) {
                foundDuration = parsedDuration
            }
        }

        if foundArtists.isEmpty {
            let fallbackParts = bylineRuns
                .compactMap { $0["text"] as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0 != "•" && $0 != "-" }
                .filter {
                    !(($0.contains(":")) && Self.parseDuration($0) != nil)
                }

            if let firstArtist = fallbackParts.first {
                foundArtists = [firstArtist]
            }

            if foundAlbum == nil, fallbackParts.count > 1 {
                foundAlbum = fallbackParts[1]
            }
        }

        self.artists = foundArtists
        self.album = foundAlbum

        if foundDuration == nil,
           let lengthData = data["lengthText"] as? [String: Any],
           let simpleLength = lengthData["simpleText"] as? String {
            foundDuration = Self.parseDuration(simpleLength)
        }

        self.duration = foundDuration

        if let thumbnail = data["thumbnail"] as? [String: Any],
           let thumbs = thumbnail["thumbnails"] as? [[String: Any]],
           let urlString = thumbs.last?["url"] as? String {
            self.thumbnailURL = URL(string: urlString)
        } else {
            self.thumbnailURL = nil
        }

        var explicitBadgeFound = false
        if let badges = data["badges"] as? [[String: Any]] {
            for badge in badges {
                if let renderer = badge["musicInlineBadgeRenderer"] as? [String: Any],
                   let icon = renderer["icon"] as? [String: Any],
                   let type = icon["iconType"] as? String,
                   type == "MUSIC_EXPLICIT_BADGE" {
                    explicitBadgeFound = true
                    break
                }
            }
        }

        self.isExplicit = explicitBadgeFound
    }
    
    private static func parseDuration(_ string: String) -> TimeInterval? {
        let parts = string.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return (parts[0] * 60) + parts[1] }
        if parts.count == 3 { return (parts[0] * 3600) + (parts[1] * 60) + parts[2] }
        return nil
    }
}

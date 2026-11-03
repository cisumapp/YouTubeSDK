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
           let title = titleText.first?["text"] as? String
        {
            self.title = title
        } else if let runs = (data["title"] as? [String: Any])?["runs"] as? [[String: Any]] {
            // A vertical shelf ("Top songs") carries its title itself rather than in a header.
            self.title = runs.compactMap { $0["text"] as? String }.joined()
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

            if let tile = itemDict["musicTwoRowItemRenderer"] as? [String: Any] {
                return Self.item(fromTile: tile)
            }
            return nil
        }
    }

    /// A carousel tile (`musicTwoRowItemRenderer`): an album, single, playlist or artist that
    /// opens a page, or a video that plays. The tile carries raw runs, not the flattened keys the
    /// models' `init?(from:)` read, so it is unpacked here.
    ///
    /// The subtitle depends on the page: "2021" or "Single • 2021" on an artist page, "Album •
    /// Radiohead • 1997" in search, "Radiohead • 1.6B views" for a video.
    static func item(fromTile tile: [String: Any]) -> YouTubeMusicItem? {
        func runs(_ key: String) -> [String] {
            ((tile[key] as? [String: Any])?["runs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        }
        let title = runs("title").joined()
        guard !title.isEmpty else { return nil }
        let details = runs("subtitle").filter { $0 != " • " }

        let thumbnails = (((tile["thumbnailRenderer"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = (thumbnails?.last?["url"] as? String).flatMap(URL.init(string:))
        let navigation = tile["navigationEndpoint"] as? [String: Any]

        if let videoID = (navigation?["watchEndpoint"] as? [String: Any])?["videoId"] as? String {
            return .song(YouTubeMusicSong(
                id: videoID, title: title, artists: details.first.map { [$0] } ?? [], album: nil, duration: nil,
                thumbnailURL: thumbnailURL, videoId: videoID, isExplicit: false, videoType: .find(in: tile)
            ))
        }

        guard let browse = navigation?["browseEndpoint"] as? [String: Any],
              let browseID = browse["browseId"] as? String
        else { return nil }
        let pageType = ((browse["browseEndpointContextSupportedConfigs"] as? [String: Any])?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"] as? String

        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM":
            let kinds: Set<String> = ["Album", "Single", "EP"]
            let year = details.last { $0.count == 4 && Int($0) != nil }
            let artist = details.first { !kinds.contains($0) && $0 != year }
            return .album(YouTubeMusicAlbum(id: browseID, title: title, artist: artist, year: year, thumbnailURL: thumbnailURL, explicit: false))
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            let author = details.first == "Playlist" ? details.dropFirst().first : details.first
            return .playlist(YouTubeMusicPlaylist(id: browseID, title: title, author: author, count: nil, thumbnailURL: thumbnailURL))
        case "MUSIC_PAGE_TYPE_ARTIST":
            return .artist(YouTubeMusicArtist(id: browseID, name: title, thumbnailURL: thumbnailURL, subscriberCount: details.first))
        default:
            return nil
        }
    }
}

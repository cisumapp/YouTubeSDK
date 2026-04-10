//
//  YouTubeMusicClient+Parsing.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

extension YouTubeMusicClient {
    
    // MARK: - Internal Parsing Helpers
    
    func parseMusicItems(from data: Data) -> [YouTubeMusicSong] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var songs: [YouTubeMusicSong] = []
        var seenVideoIDs = Set<String>()

        // Search top result commonly arrives inside musicCardShelfRenderer.
        let cardShelves = findAll(key: "musicCardShelfRenderer", in: json)
        for shelf in cardShelves {
            let cardItems = findAll(key: "musicResponsiveListItemRenderer", in: shelf)
            for item in cardItems {
                guard let dict = item as? [String: Any],
                      let song = YouTubeMusicSong(from: dict),
                      seenVideoIDs.insert(song.videoId).inserted else {
                    continue
                }
                songs.append(song)
            }
        }

        let items = findAll(key: "musicResponsiveListItemRenderer", in: json)
        for item in items {
            guard let dict = item as? [String: Any],
                  let song = YouTubeMusicSong(from: dict),
                  seenVideoIDs.insert(song.videoId).inserted else {
                continue
            }
            songs.append(song)
        }

        return songs
    }

    func parseHomePage(from data: Data) -> YouTubeMusicHomePage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return YouTubeMusicHomePage(sections: [], continuationToken: nil)
        }

        let sections = parseSections(from: json)
        let continuationToken = findContinuationToken(in: json)
        return YouTubeMusicHomePage(sections: sections, continuationToken: continuationToken)
    }

    func parseRadioQueue(from data: Data) -> YouTubeMusicRadioQueue {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return YouTubeMusicRadioQueue(items: [], continuationToken: nil, playlistId: nil)
        }

        var songs: [YouTubeMusicSong] = []
        var seenVideoIDs = Set<String>()

        let panelRenderers = extractPlaylistPanelVideoRenderers(in: json)
        for renderer in panelRenderers {
            guard let song = YouTubeMusicSong(fromPlaylistPanelRenderer: renderer),
                  seenVideoIDs.insert(song.videoId).inserted else {
                continue
            }
            songs.append(song)
        }

        if songs.isEmpty {
            let fallbackItems = findAll(key: "musicResponsiveListItemRenderer", in: json)
            for item in fallbackItems {
                guard let dict = item as? [String: Any],
                      let song = YouTubeMusicSong(from: dict),
                      seenVideoIDs.insert(song.videoId).inserted else {
                    continue
                }
                songs.append(song)
            }
        }

        let continuationToken = findNextRadioContinuationToken(in: json) ?? findContinuationToken(in: json)
        let playlistId = findPlaylistID(in: json)

        return YouTubeMusicRadioQueue(items: songs, continuationToken: continuationToken, playlistId: playlistId)
    }

    func parseSongMetadata(from data: Data, fallbackVideoID: String) -> YouTubeMusicSongMetadata {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return YouTubeMusicSongMetadata(
                song: nil,
                videoId: fallbackVideoID,
                playlistId: nil,
                continuationToken: nil,
                feedbackTokens: YouTubeMusicFeedbackTokens(primary: nil, undo: nil, all: [])
            )
        }

        let renderers = extractPlaylistPanelVideoRenderers(in: json)
        let selected = renderers.first(where: { ($0["selected"] as? Bool) == true }) ?? renderers.first
        let selectedSong = selected.flatMap { YouTubeMusicSong(fromPlaylistPanelRenderer: $0) }
        let videoID = selectedSong?.videoId ?? fallbackVideoID

        return YouTubeMusicSongMetadata(
            song: selectedSong,
            videoId: videoID,
            playlistId: findPlaylistID(in: json),
            continuationToken: findNextRadioContinuationToken(in: json) ?? findContinuationToken(in: json),
            feedbackTokens: extractFeedbackTokens(in: json)
        )
    }

    func parseLibraryLanding(from data: Data) -> YouTubeMusicLibraryLanding {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return YouTubeMusicLibraryLanding(sections: [], filterChips: [], continuationToken: nil)
        }

        let sections = parseSections(from: json)
        let chips = parseLibraryFilterChips(in: json)
        return YouTubeMusicLibraryLanding(
            sections: sections,
            filterChips: chips,
            continuationToken: findContinuationToken(in: json)
        )
    }

    func parseAccountsList(from data: Data) -> YouTubeMusicAccountsList {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return YouTubeMusicAccountsList(primaryEmail: nil, accounts: [])
        }

        let accounts = extractBrandAccounts(in: json)
        let primaryEmail = findFirstString(forKeys: ["email", "emailAddress"], in: json)
        return YouTubeMusicAccountsList(primaryEmail: primaryEmail, accounts: accounts)
    }
    
    func parseSections(from json: [String: Any]) -> [YouTubeMusicSection] {
        var sections: [YouTubeMusicSection] = []
        
        // 1. Carousels (Horizontal)
        let carousels = findAll(key: "musicCarouselShelfRenderer", in: json)
        for carousel in carousels {
            if let dict = carousel as? [String: Any],
               let section = YouTubeMusicSection(from: dict) {
                sections.append(section)
            }
        }
        
        // 2. Shelves (Vertical)
        let shelves = findAll(key: "musicShelfRenderer", in: json)
        for shelf in shelves {
            if let dict = shelf as? [String: Any],
               let section = YouTubeMusicSection(from: dict) {
                sections.append(section)
            }
        }
        
        return sections
    }
    
    /// Recursively finds all dictionaries with a specific key.
    func findAll(key: String, in container: Any) -> [Any] {
        var results: [Any] = []
        if let dict = container as? [String: Any] {
            if let found = dict[key] { results.append(found) }
            for value in dict.values { results.append(contentsOf: findAll(key: key, in: value)) }
        } else if let array = container as? [Any] {
            for element in array { results.append(contentsOf: findAll(key: key, in: element)) }
        }
        return results
    }

    func findContinuationToken(in container: Any) -> String? {
        if let dict = container as? [String: Any] {
            if let token = dict["continuation"] as? String { return token }
            if let continuationData = (dict["continuationEndpoint"] as? [String: Any])?["continuationCommand"] as? [String: Any],
               let token = continuationData["token"] as? String {
                return token
            }
            for value in dict.values {
                if let found = findContinuationToken(in: value) {
                    return found
                }
            }
        } else if let array = container as? [Any] {
            for element in array {
                if let found = findContinuationToken(in: element) {
                    return found
                }
            }
        }
        return nil
    }

    func findNextRadioContinuationToken(in container: Any) -> String? {
        if let dict = container as? [String: Any] {
            if let nextRadio = dict["nextRadioContinuationData"] as? [String: Any],
               let token = nextRadio["continuation"] as? String {
                return token
            }

            for value in dict.values {
                if let found = findNextRadioContinuationToken(in: value) {
                    return found
                }
            }
        } else if let array = container as? [Any] {
            for element in array {
                if let found = findNextRadioContinuationToken(in: element) {
                    return found
                }
            }
        }

        return nil
    }

    func findPlaylistID(in container: Any) -> String? {
        if let dict = container as? [String: Any] {
            if let playlistId = dict["playlistId"] as? String, !playlistId.isEmpty {
                return playlistId
            }

            if let watchEndpoint = dict["watchEndpoint"] as? [String: Any],
               let playlistId = watchEndpoint["playlistId"] as? String,
               !playlistId.isEmpty {
                return playlistId
            }

            for value in dict.values {
                if let found = findPlaylistID(in: value) {
                    return found
                }
            }
        } else if let array = container as? [Any] {
            for element in array {
                if let found = findPlaylistID(in: element) {
                    return found
                }
            }
        }

        return nil
    }

    private func extractPlaylistPanelVideoRenderers(in container: Any) -> [[String: Any]] {
        var renderers = findAll(key: "playlistPanelVideoRenderer", in: container)
            .compactMap { $0 as? [String: Any] }

        let wrappers = findAll(key: "playlistPanelVideoWrapperRenderer", in: container)
        for wrapper in wrappers {
            guard let dict = wrapper as? [String: Any],
                  let primary = dict["primaryRenderer"] as? [String: Any],
                  let renderer = primary["playlistPanelVideoRenderer"] as? [String: Any] else {
                continue
            }
            renderers.append(renderer)
        }

        return renderers
    }

    private func parseLibraryFilterChips(in container: Any) -> [YouTubeMusicLibraryFilterChip] {
        let chips = findAll(key: "chipCloudChipRenderer", in: container)

        var parsed: [YouTubeMusicLibraryFilterChip] = []
        var seen = Set<String>()
        for chip in chips {
            guard let dict = chip as? [String: Any] else { continue }

            let title = resolveText(from: dict["text"]) ?? resolveText(from: dict["title"]) ?? "Filter"

            let browseEndpoint = extractBrowseEndpoint(from: dict)
            guard let browseId = browseEndpoint?["browseId"] as? String,
                  !browseId.isEmpty else {
                continue
            }

            let params = browseEndpoint?["params"] as? String
            let chipModel = YouTubeMusicLibraryFilterChip(title: title, browseId: browseId, params: params)
            guard seen.insert(chipModel.id).inserted else { continue }
            parsed.append(chipModel)
        }

        return parsed
    }

    private func extractBrowseEndpoint(from container: [String: Any]) -> [String: Any]? {
        if let browse = container["browseEndpoint"] as? [String: Any] {
            return browse
        }

        for value in container.values {
            if let dict = value as? [String: Any],
               let nested = extractBrowseEndpoint(from: dict) {
                return nested
            }
            if let array = value as? [Any] {
                for entry in array {
                    if let dict = entry as? [String: Any],
                       let nested = extractBrowseEndpoint(from: dict) {
                        return nested
                    }
                }
            }
        }

        return nil
    }

    private func extractBrandAccounts(in container: Any) -> [YouTubeMusicBrandAccount] {
        var results: [YouTubeMusicBrandAccount] = []
        var seenPageIDs = Set<String>()

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let serviceEndpoint = dict["serviceEndpoint"] as? [String: Any],
                   let selectIdentity = serviceEndpoint["selectActiveIdentityEndpoint"] as? [String: Any],
                   let supportedTokens = selectIdentity["supportedTokens"] as? [[String: Any]] {
                    let pageID = supportedTokens
                        .compactMap { ($0["pageIdToken"] as? [String: Any])?["pageId"] as? String }
                        .first { !$0.isEmpty }

                    if let pageID,
                       seenPageIDs.insert(pageID).inserted {
                        let name = resolveText(from: dict["accountName"]) ?? resolveText(from: dict["title"]) ?? "Unknown Account"
                        let handle = resolveText(from: dict["channelHandle"])
                        let isSelected = (dict["isSelected"] as? Bool) ?? false
                        results.append(
                            YouTubeMusicBrandAccount(
                                pageId: pageID,
                                name: name,
                                handle: handle,
                                isSelected: isSelected
                            )
                        )
                    }
                }

                for value in dict.values {
                    walk(value)
                }
            } else if let array = node as? [Any] {
                for value in array {
                    walk(value)
                }
            }
        }

        walk(container)
        return results
    }

    private func extractFeedbackTokens(in container: Any) -> YouTubeMusicFeedbackTokens {
        var primary: String?
        var undo: String?
        var all: [String] = []
        var seen = Set<String>()

        func capture(_ token: String) {
            guard !token.isEmpty, seen.insert(token).inserted else { return }
            all.append(token)
        }

        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let feedbackToken = dict["feedbackToken"] as? String {
                    if primary == nil {
                        primary = feedbackToken
                    }
                    capture(feedbackToken)
                }

                if let undoToken = dict["undoFeedbackToken"] as? String {
                    if undo == nil {
                        undo = undoToken
                    }
                    capture(undoToken)
                }

                for value in dict.values {
                    walk(value)
                }
            } else if let array = node as? [Any] {
                for value in array {
                    walk(value)
                }
            }
        }

        walk(container)
        return YouTubeMusicFeedbackTokens(primary: primary, undo: undo, all: all)
    }

    private func resolveText(from value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let dict = value as? [String: Any] else {
            return nil
        }

        if let simple = dict["simpleText"] as? String {
            let trimmed = simple.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs
                .compactMap { $0["text"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }

        return nil
    }

    private func findFirstString(forKeys keys: [String], in container: Any) -> String? {
        if let dict = container as? [String: Any] {
            for key in keys {
                if let value = dict[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }

            for value in dict.values {
                if let found = findFirstString(forKeys: keys, in: value) {
                    return found
                }
            }
        } else if let array = container as? [Any] {
            for value in array {
                if let found = findFirstString(forKeys: keys, in: value) {
                    return found
                }
            }
        }

        return nil
    }
}

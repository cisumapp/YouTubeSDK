//
//  YouTubeMusicClient+Discovery.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

extension YouTubeMusicClient {
    
    public func getHome() async throws -> [YouTubeMusicSection] {
        let page = try await getHomePage()
        return page.sections
    }

    public func getHomePage(regionCode: String? = nil, languageCode: String? = nil) async throws -> YouTubeMusicHomePage {
        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let body = ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.home]
        let data = try await client.get("browse", body: body)
        return parseHomePage(from: data)
    }

    public func getHomeContinuation(
        token: String,
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> YouTubeMusicHomePage {
        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let data = try await client.get("browse", body: ["continuation": token])
        return parseHomePage(from: data)
    }

    public func getRecommendedSongs(
        limit: Int = 25,
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> [YouTubeMusicSong] {
        let cappedLimit = max(1, limit)

        var seenVideoIDs = Set<String>()
        var collectedSongs: [YouTubeMusicSong] = []
        var page = try await getHomePage(regionCode: regionCode, languageCode: languageCode)

        collectedSongs.append(contentsOf: extractUniqueSongs(from: page.items, seenVideoIDs: &seenVideoIDs))

        var visitedTokens = Set<String>()
        while collectedSongs.count < cappedLimit,
              let continuationToken = page.continuationToken,
              visitedTokens.insert(continuationToken).inserted {
            page = try await getHomeContinuation(
                token: continuationToken,
                regionCode: regionCode,
                languageCode: languageCode
            )
            collectedSongs.append(contentsOf: extractUniqueSongs(from: page.items, seenVideoIDs: &seenVideoIDs))
        }

        return Array(collectedSongs.prefix(cappedLimit))
    }

    public func getSong(
        videoId: String,
        playlistId: String? = nil,
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> YouTubeMusicSongMetadata {
        guard let normalizedVideoId = normalizedVideoID(videoId) else {
            throw YouTubeError.apiError(message: "Invalid videoId")
        }

        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        var body: [String: String] = ["videoId": normalizedVideoId]
        if let playlistId = normalizedToken(playlistId) {
            body["playlistId"] = playlistId
        }

        let data = try await client.get("next", body: body)
        return parseSongMetadata(from: data, fallbackVideoID: normalizedVideoId)
    }

    public func getRadio(
        videoId: String,
        playlistId: String? = nil,
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> YouTubeMusicRadioQueue {
        guard let normalizedVideoId = normalizedVideoID(videoId) else {
            throw YouTubeError.apiError(message: "Invalid videoId for radio")
        }

        let trimmedPlaylistId = playlistId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPlaylistId: String
        if let trimmedPlaylistId, !trimmedPlaylistId.isEmpty {
            resolvedPlaylistId = trimmedPlaylistId
        } else {
            resolvedPlaylistId = "RDAMVM\(normalizedVideoId)"
        }

        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let data = try await client.get("next", body: [
            "videoId": normalizedVideoId,
            "playlistId": resolvedPlaylistId
        ])

        let parsed = parseRadioQueue(from: data)
        if parsed.playlistId == nil {
            return YouTubeMusicRadioQueue(
                items: parsed.items,
                continuationToken: parsed.continuationToken,
                playlistId: resolvedPlaylistId
            )
        }

        return parsed
    }

    public func getRadioContinuation(
        token: String,
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> YouTubeMusicRadioQueue {
        guard let normalizedToken = normalizedToken(token) else {
            throw YouTubeError.apiError(message: "Invalid continuation token")
        }

        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let data = try await client.get("next", body: ["continuation": normalizedToken])
        return parseRadioQueue(from: data)
    }

    public func getQueue(playlistId: String, regionCode: String? = nil, languageCode: String? = nil) async throws -> [YouTubeMusicSong] {
        guard let normalizedPlaylistId = normalizedToken(playlistId) else {
            throw YouTubeError.apiError(message: "Invalid playlistId")
        }

        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let data = try await client.get("music/get_queue", body: ["playlistId": normalizedPlaylistId])
        return parseRadioQueue(from: data).items
    }

    // MARK: - Library Coverage

    public func getLibraryLanding(
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil
    ) async throws -> YouTubeMusicLibraryLanding {
        let client = makeNetwork(
            regionCode: regionCode,
            languageCode: languageCode,
            brandAccountID: brandAccountID
        )
        let data = try await client.get("browse", body: [
            "browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.libraryLanding
        ])
        return parseLibraryLanding(from: data)
    }

    public func getLibraryFilterContent(
        browseId: String,
        params: String? = nil,
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil
    ) async throws -> [YouTubeMusicSection] {
        guard let normalizedBrowseID = normalizedToken(browseId) else {
            throw YouTubeError.apiError(message: "Invalid library browseId")
        }

        let client = makeNetwork(
            regionCode: regionCode,
            languageCode: languageCode,
            brandAccountID: brandAccountID
        )

        var body: [String: String] = ["browseId": normalizedBrowseID]
        if let params = normalizedToken(params) {
            body["params"] = params
        }

        let data = try await client.get("browse", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parseSections(from: json)
    }

    public func getLibraryPlaylists(
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil
    ) async throws -> [YouTubeMusicSection] {
        try await getLibraryFilterContent(
            browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.likedPlaylists,
            regionCode: regionCode,
            languageCode: languageCode,
            brandAccountID: brandAccountID
        )
    }

    public func getLibraryArtists(
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil,
        preferCorpusArtists: Bool = true
    ) async throws -> [YouTubeMusicSection] {
        let browseId = preferCorpusArtists
            ? YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.libraryCorpusArtists
            : YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.libraryCorpusTrackArtists

        return try await getLibraryFilterContent(
            browseId: browseId,
            regionCode: regionCode,
            languageCode: languageCode,
            brandAccountID: brandAccountID
        )
    }

    public func getLibraryAlbums(
        params: String? = nil,
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil
    ) async throws -> [YouTubeMusicSection] {
        try await getLibraryFilterContent(
            browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.libraryAlbums,
            params: params,
            regionCode: regionCode,
            languageCode: languageCode,
            brandAccountID: brandAccountID
        )
    }

    public func getLibrarySongs(
        params: String? = nil,
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil
    ) async throws -> [YouTubeMusicSection] {
        try await getLibraryFilterContent(
            browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.librarySongs,
            params: params,
            regionCode: regionCode,
            languageCode: languageCode,
            brandAccountID: brandAccountID
        )
    }

    // MARK: - Account Coverage

    public func getAccountsList(
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> YouTubeMusicAccountsList {
        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let data = try await client.get("account/accounts_list", body: [:])
        return parseAccountsList(from: data)
    }

    public func getBrandAccounts(
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> [YouTubeMusicBrandAccount] {
        let accountList = try await getAccountsList(regionCode: regionCode, languageCode: languageCode)
        return accountList.accounts
    }
    
    public func getCharts() async throws -> [YouTubeMusicSection] {
        return try await browseSection(browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.charts)
    }
    
    public func getNewReleases() async throws -> [YouTubeMusicSection] {
        return try await browseSection(browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.newReleases)
    }
    
    public func getMoods() async throws -> [YouTubeMusicSection] {
        return try await browseSection(browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.moods)
    }
    
    // MARK: - User Library
        
    public func getLikedSongs() async throws -> [YouTubeMusicSong] {
        let primaryData = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.likedMusic])
        let primaryResults = parseMusicItems(from: primaryData)
        if !primaryResults.isEmpty {
            return primaryResults
        }

        let fallbackData = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.likedVideos])
        return parseMusicItems(from: fallbackData)
    }
    
    public func getHistory() async throws -> [YouTubeMusicSong] {
        let data = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.history])
        return parseMusicItems(from: data)
    }
    
    public func getLibrary() async throws -> [YouTubeMusicSection] {
        let data = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.library])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parseSections(from: json)
    }
    
    private func browseSection(browseId: String) async throws -> [YouTubeMusicSection] {
        let body = ["browseId": browseId]
        let data = try await network.get("browse", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return parseSections(from: json)
    }

    private func makeNetwork(
        regionCode: String?,
        languageCode: String?,
        brandAccountID: String? = nil
    ) -> NetworkClient {
        let normalizedBrandAccountID = normalizedToken(brandAccountID)
        let normalizedRegion = normalizedRegionCode(regionCode)

        guard normalizedRegion != nil || normalizedBrandAccountID != nil else {
            return network
        }

        let normalizedLanguage = normalizedLanguageCode(languageCode)
        let context = InnerTubeContext(
            client: ClientConfig.webRemix,
            cookies: cookies,
            gl: normalizedRegion ?? "US",
            hl: normalizedLanguage,
            onBehalfOfUser: normalizedBrandAccountID
        )
        return NetworkClient(context: context, baseURL: YouTubeSDKConstants.URLS.API.youtubeMusicInnerTubeURL)
    }

    private func normalizedRegionCode(_ rawRegionCode: String?) -> String? {
        guard let raw = rawRegionCode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let uppercased = raw.uppercased()
        guard uppercased.count == 2 else { return nil }
        return uppercased
    }

    private func normalizedLanguageCode(_ rawLanguageCode: String?) -> String {
        guard let raw = rawLanguageCode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "en"
        }

        if let separator = raw.firstIndex(where: { $0 == "-" || $0 == "_" }) {
            return String(raw[..<separator]).lowercased()
        }

        return raw.lowercased()
    }

    private func normalizedToken(_ rawToken: String?) -> String? {
        guard let rawToken else { return nil }

        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func normalizedVideoID(_ rawVideoID: String) -> String? {
        let trimmed = rawVideoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func extractUniqueSongs(from items: [YouTubeMusicItem], seenVideoIDs: inout Set<String>) -> [YouTubeMusicSong] {
        var songs: [YouTubeMusicSong] = []

        for item in items {
            guard case .song(let song) = item,
                  seenVideoIDs.insert(song.videoId).inserted else {
                continue
            }
            songs.append(song)
        }

        return songs
    }
}

//
//  YouTubeMusicClient+Discovery.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 13/03/26.
//

import Foundation

public extension YouTubeMusicClient {
    func getHome() async throws -> [YouTubeMusicSection] {
        let page = try await getHomePage()
        return page.sections
    }

    func getHomePage(regionCode: String? = nil, languageCode: String? = nil) async throws -> YouTubeMusicHomePage {
        let body = ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.home]
        let data = try await browseData(body: body, regionCode: regionCode, languageCode: languageCode)
        return parseHomePage(from: data)
    }

    func getHomeContinuation(
        token: String,
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> YouTubeMusicHomePage {
        let data = try await browseData(body: ["continuation": token], regionCode: regionCode, languageCode: languageCode)
        return parseHomePage(from: data)
    }

    func getRecommendedSongs(
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
              visitedTokens.insert(continuationToken).inserted
        {
            page = try await getHomeContinuation(
                token: continuationToken,
                regionCode: regionCode,
                languageCode: languageCode
            )
            collectedSongs.append(contentsOf: extractUniqueSongs(from: page.items, seenVideoIDs: &seenVideoIDs))
        }

        return Array(collectedSongs.prefix(cappedLimit))
    }

    func getSong(
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

    func getRadio(
        videoId: String,
        playlistId: String? = nil,
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> YouTubeMusicRadioQueue {
        guard let normalizedVideoId = normalizedVideoID(videoId) else {
            throw YouTubeError.apiError(message: "Invalid videoId for radio")
        }

        let trimmedPlaylistId = playlistId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPlaylistId: String = if let trimmedPlaylistId, !trimmedPlaylistId.isEmpty {
            trimmedPlaylistId
        } else {
            "RDAMVM\(normalizedVideoId)"
        }

        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let data = try await client.get("next", body: [
            "videoId": normalizedVideoId,
            "playlistId": resolvedPlaylistId,
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

    func getRadioContinuation(
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

    func getQueue(playlistId: String, regionCode: String? = nil, languageCode: String? = nil) async throws -> [YouTubeMusicSong] {
        guard let normalizedPlaylistId = normalizedToken(playlistId) else {
            throw YouTubeError.apiError(message: "Invalid playlistId")
        }

        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let data = try await client.get("music/get_queue", body: ["playlistId": normalizedPlaylistId])
        return parseRadioQueue(from: data).items
    }

    // MARK: - Library Coverage

    func getLibraryLanding(
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil
    ) async throws -> YouTubeMusicLibraryLanding {
        let data = try await browseData(body: [
            "browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.libraryLanding,
        ], regionCode: regionCode, languageCode: languageCode, brandAccountID: brandAccountID)
        return parseLibraryLanding(from: data)
    }

    func getLibraryFilterContent(
        browseId: String,
        params: String? = nil,
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil
    ) async throws -> [YouTubeMusicSection] {
        guard let normalizedBrowseID = normalizedToken(browseId) else {
            throw YouTubeError.apiError(message: "Invalid library browseId")
        }

        var body: [String: String] = ["browseId": normalizedBrowseID]
        if let params = normalizedToken(params) {
            body["params"] = params
        }

        let data = try await browseData(body: body, regionCode: regionCode, languageCode: languageCode, brandAccountID: brandAccountID)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return parseSections(from: json)
    }

    func getLibraryPlaylists(
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

    func getLibraryArtists(
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

    func getLibraryAlbums(
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

    func getLibrarySongs(
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

    func getAccountsList(
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> YouTubeMusicAccountsList {
        let client = makeNetwork(regionCode: regionCode, languageCode: languageCode)
        let data = try await client.get("account/accounts_list", body: [:])
        return parseAccountsList(from: data)
    }

    func getBrandAccounts(
        regionCode: String? = nil,
        languageCode: String? = nil
    ) async throws -> [YouTubeMusicBrandAccount] {
        let accountList = try await getAccountsList(regionCode: regionCode, languageCode: languageCode)
        return accountList.accounts
    }

    func getCharts() async throws -> [YouTubeMusicSection] {
        try await browseSection(browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.charts)
    }

    func getNewReleases() async throws -> [YouTubeMusicSection] {
        try await browseSection(browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.newReleases)
    }

    func getMoods() async throws -> [YouTubeMusicSection] {
        try await browseSection(browseId: YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.moods)
    }

    // MARK: - User Library

    func getLikedSongs() async throws -> [YouTubeMusicSong] {
        let primaryData = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.likedMusic])
        let primaryResults = parseMusicItems(from: primaryData)
        if !primaryResults.isEmpty {
            return primaryResults
        }

        let fallbackData = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.likedVideos])
        return parseMusicItems(from: fallbackData)
    }

    func getHistory() async throws -> [YouTubeMusicSong] {
        let data = try await network.get("browse", body: ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.history])
        return parseMusicItems(from: data)
    }

    func getLibrary() async throws -> [YouTubeMusicSection] {
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
        brandAccountID: String? = nil,
        client: ClientConfig = .webRemix
    ) -> NetworkClient {
        let normalizedBrandAccountID = normalizedToken(brandAccountID)
        let normalizedRegion = normalizedRegionCode(regionCode)

        guard normalizedRegion != nil || normalizedBrandAccountID != nil else {
            if client.name == ClientConfig.webRemix.name {
                return network
            }
            let context = InnerTubeContext(client: client, cookies: cookies, accessToken: accessToken)
            return NetworkClient(context: context, baseURL: YouTubeSDKConstants.URLS.API.youtubeMusicInnerTubeURL)
        }

        let normalizedLanguage = normalizedLanguageCode(languageCode)
        let context = InnerTubeContext(
            client: client,
            cookies: cookies,
            gl: normalizedRegion ?? "US",
            hl: normalizedLanguage,
            onBehalfOfUser: normalizedBrandAccountID
        )
        return NetworkClient(context: context, baseURL: YouTubeSDKConstants.URLS.API.youtubeMusicInnerTubeURL)
    }

    private func browseData(
        body: [String: String],
        regionCode: String? = nil,
        languageCode: String? = nil,
        brandAccountID: String? = nil
    ) async throws -> Data {
        let primary = makeNetwork(regionCode: regionCode, languageCode: languageCode, brandAccountID: brandAccountID, client: .webRemix)
        do {
            return try await primary.get("browse", body: body)
        } catch {
            let fallbackClients: [ClientConfig] = [.androidMusic, .iosMusic]
            for client in fallbackClients {
                let fallback = makeNetwork(regionCode: regionCode, languageCode: languageCode, brandAccountID: brandAccountID, client: client)
                if let data = try? await fallback.get("browse", body: body) {
                    return data
                }
            }
            throw error
        }
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
        // Validate YouTube video ID: exactly 11 chars of [A-Za-z0-9_-]
        guard trimmed.count == 11 else { return nil }
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard trimmed.unicodeScalars.allSatisfy({ validChars.contains($0) }) else { return nil }
        return trimmed
    }

    private func extractUniqueSongs(from items: [YouTubeMusicItem], seenVideoIDs: inout Set<String>) -> [YouTubeMusicSong] {
        let songs = items.compactMap { item -> YouTubeMusicSong? in
            guard case let .song(song) = item else { return nil }
            return song
        }

        return songs.filter { seenVideoIDs.insert($0.videoId).inserted }
    }
}

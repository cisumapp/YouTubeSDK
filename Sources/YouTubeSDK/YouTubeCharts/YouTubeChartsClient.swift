//
//  YouTubeChartsClient.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

public actor YouTubeChartsClient {
    
    private let analyticsNetwork: NetworkClient
    private let musicNetwork: NetworkClient
    
    public init() {
        let analyticsContext = InnerTubeContext(client: ClientConfig.webMusicAnalytics)
        self.analyticsNetwork = NetworkClient(
            context: analyticsContext,
            baseURL: YouTubeSDKConstants.URLS.API.youtubeChartsInnerTubeURL
        )

        let musicContext = InnerTubeContext(client: ClientConfig.webRemix)
        self.musicNetwork = NetworkClient(context: musicContext, baseURL: YouTubeSDKConstants.URLS.API.youtubeMusicInnerTubeURL)
    }
    
    // MARK: - Global & Local Charts
    
    /// Top Songs Chart
    /// - Parameter country: ISO 3166-1 alpha-2 code (e.g., "US", "IN", "JP", "ZZ" for Global)
    public func getTopSongs(country: String = "ZZ") async throws -> [YouTubeChartItem] {
        return try await fetchChart(country: country, type: .song, sectionKeywords: ["song"])
    }
    
    /// Top Music Videos Chart
    public func getTopVideos(country: String = "ZZ") async throws -> [YouTubeChartItem] {
        return try await fetchChart(country: country, type: .video, sectionKeywords: ["video"])
    }
    
    /// Top Artists Chart
    public func getTopArtists(country: String = "ZZ") async throws -> [YouTubeChartItem] {
        return try await fetchChart(country: country, type: .artist, sectionKeywords: ["artist"])
    }
    
    /// Trending (Global/Local)
    public func getTrending(country: String = "ZZ") async throws -> [YouTubeChartItem] {
        return try await fetchChart(country: country, type: .video, sectionKeywords: ["trending", "video"])
    }
    
    // MARK: - Private Helpers
    
    private func fetchChart(
        country: String,
        type: YouTubeChartItem.ChartItemType,
        sectionKeywords: [String]
    ) async throws -> [YouTubeChartItem] {
        let countryCode = normalizedCountryCode(country)

        if let analyticsData = try? await analyticsNetwork.sendComplexRequest(
            "browse",
            body: [
                "browseId": "FEmusic_analytics_charts_home",
                "query": "perspective=CHART_HOME&chart_params_country_code=\(countryCode)"
            ],
            queryItems: [URLQueryItem(name: "alt", value: "json")],
            additionalHeaders: ["X-Goog-Api-Format-Version": "2"]
        ) {
            let parsedHome = parseCharts(from: analyticsData, type: type, sectionKeywords: sectionKeywords)
            if !parsedHome.isEmpty {
                return parsedHome
            }
        }

        if let legacyAnalyticsData = try? await analyticsNetwork.sendComplexRequest(
            "browse",
            body: ["browseId": legacyBrowseID(for: type)],
            queryItems: [URLQueryItem(name: "alt", value: "json")],
            additionalHeaders: ["X-Goog-Api-Format-Version": "2"]
        ) {
            let parsedLegacy = parseCharts(from: legacyAnalyticsData, type: type, sectionKeywords: sectionKeywords)
            if !parsedLegacy.isEmpty {
                return parsedLegacy
            }
        }

        // Last-resort fallback for clients that still reject analytics profiles.
        let fallbackBody: [String: Any] = ["browseId": YouTubeSDKConstants.InternalKeys.BrowseIDs.Music.charts]
        let fallbackData = try await musicNetwork.sendComplexRequest("browse", body: fallbackBody)
        return parseCharts(from: fallbackData, type: type, sectionKeywords: sectionKeywords)
    }

    private nonisolated func normalizedCountryCode(_ country: String) -> String {
        let normalized = country.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized.uppercased() == "ZZ" || normalized.lowercased() == "global" {
            return "global"
        }
        return normalized.lowercased()
    }

    private nonisolated func legacyBrowseID(for type: YouTubeChartItem.ChartItemType) -> String {
        switch type {
        case .song:
            return "FEmusic_analytics_charts_songs"
        case .video:
            return "FEmusic_analytics_charts_videos"
        case .artist:
            return "FEmusic_analytics_charts_artists"
        }
    }
    
    // MARK: - Parsing Logic
    
    private func parseCharts(
        from data: Data,
        type: YouTubeChartItem.ChartItemType,
        sectionKeywords: [String]
    ) -> [YouTubeChartItem] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        let analyticsSections = findAll(key: "musicAnalyticsSectionRenderer", in: json).compactMap { $0 as? [String: Any] }
        let analyticsItems = parseAnalyticsSections(
            analyticsSections,
            type: type,
            sectionKeywords: sectionKeywords
        )
        if !analyticsItems.isEmpty {
            return analyticsItems
        }
        
        var items: [YouTubeChartItem] = []
        var seenIDs = Set<String>()
        
        // Charts uses "musicResponsiveListItemRenderer" (Songs/Videos) and "musicTableRowRenderer" (Artists)
        let rowRenderers = findAll(key: "musicResponsiveListItemRenderer", in: json) + findAll(key: "musicTableRowRenderer", in: json)
        
        for renderer in rowRenderers {
            if let dict = renderer as? [String: Any],
               let item = YouTubeChartItem(from: dict, type: type),
               seenIDs.insert(item.id).inserted {
                items.append(item)
            }
        }
        
        return items
    }

    private func parseAnalyticsSections(
        _ sections: [[String: Any]],
        type: YouTubeChartItem.ChartItemType,
        sectionKeywords: [String]
    ) -> [YouTubeChartItem] {
        guard !sections.isEmpty else { return [] }

        let normalizedKeywords = sectionKeywords.map { $0.lowercased() }
        let matchingSections = sections.filter { section in
            guard !normalizedKeywords.isEmpty else { return true }
            guard let title = extractText(from: section["title"])?.lowercased() else { return false }
            return normalizedKeywords.contains(where: { title.contains($0) })
        }

        let sectionsToParse = matchingSections.isEmpty ? sections : matchingSections
        var items: [YouTubeChartItem] = []
        var seenIDs = Set<String>()

        for section in sectionsToParse {
            let content = (section["content"] as? [String: Any]) ?? section
            let entries = analyticsEntries(in: content, type: type)
            for entry in entries {
                if let dict = entry as? [String: Any],
                   let item = YouTubeChartItem(from: dict, type: type),
                   seenIDs.insert(item.id).inserted {
                    items.append(item)
                }
            }
        }

        return items
    }

    private func analyticsEntries(in section: [String: Any], type: YouTubeChartItem.ChartItemType) -> [Any] {
        var entries: [Any] = []

        let preferredKeys: [String]
        switch type {
        case .song:
            preferredKeys = ["trackViews", "tracks", "songs"]
        case .video:
            preferredKeys = ["videoViews", "trendingVideos"]
        case .artist:
            preferredKeys = ["artistViews"]
        }

        for key in preferredKeys {
            if let found = entriesArray(for: key, in: section), !found.isEmpty {
                entries.append(contentsOf: found)
            }
        }

        switch type {
        case .song:
            if let trackTypes = section["trackTypes"] as? [Any] {
                for trackType in trackTypes {
                    if let trackTypeDict = trackType as? [String: Any],
                       let found = entriesArray(for: "trackViews", in: trackTypeDict),
                       !found.isEmpty {
                        entries.append(contentsOf: found)
                    }
                }
            }
        case .video:
            if let videos = section["videos"] as? [Any] {
                for videosList in videos {
                    if let videosListDict = videosList as? [String: Any],
                       let found = entriesArray(for: "videoViews", in: videosListDict),
                       !found.isEmpty {
                        entries.append(contentsOf: found)
                    }
                }
            }
        case .artist:
            if let artistsContainer = section["artists"] as? [String: Any],
               let found = entriesArray(for: "artistViews", in: artistsContainer),
               !found.isEmpty {
                entries.append(contentsOf: found)
            }
        }

        if !entries.isEmpty {
            return entries
        }

        let fallbackKeys = ["trackViews", "videoViews", "artists", "artistViews"]
        for key in fallbackKeys {
            if let found = entriesArray(for: key, in: section), !found.isEmpty {
                entries.append(contentsOf: found)
            }
        }

        return entries
    }

    private func entriesArray(for key: String, in section: [String: Any]) -> [Any]? {
        if let direct = section[key] as? [Any] {
            return direct
        }
        if let wrapped = section[key] as? [String: Any],
           let items = wrapped["items"] as? [Any] {
            return items
        }
        return nil
    }

    private func extractText(from value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = value as? [String: Any] {
            if let simpleText = dict["simpleText"] as? String {
                return simpleText
            }
            if let runs = dict["runs"] as? [[String: Any]] {
                let joined = runs.compactMap { $0["text"] as? String }.joined()
                let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return nil
    }
    
    private func findAll(key: String, in container: Any) -> [Any] {
        var results: [Any] = []
        if let dict = container as? [String: Any] {
            if let found = dict[key] { results.append(found) }
            for value in dict.values { results.append(contentsOf: findAll(key: key, in: value)) }
        } else if let array = container as? [Any] {
            for element in array { results.append(contentsOf: findAll(key: key, in: element)) }
        }
        return results
    }
}

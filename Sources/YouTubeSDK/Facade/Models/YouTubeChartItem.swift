//
//  YouTubeChartItem.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 31/12/25.
//

import Foundation

public struct YouTubeChartItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String // Artist or Channel Name
    public let rank: String
    public let thumbnailURL: URL?
    public let type: ChartItemType
    
    // Metadata
    public let viewCount: String?
    public let change: String? // e.g., "NEW", "+1", "-3"
    
    public enum ChartItemType: String, Sendable {
        case song
        case video
        case artist
    }
    
    /// Robust Initializer for Charts
    init?(from data: [String: Any], type: ChartItemType) {
        let payload = Self.unwrapAnalyticsPayload(data)

        guard let resolvedID = Self.extractID(from: payload) else { return nil }
        self.id = resolvedID
        self.type = type
        
        self.title = Self.extractText(from: payload["title"]) ?? Self.extractText(from: payload["name"]) ?? "Unknown"

        self.subtitle = Self.extractText(from: payload["subtitle"])
            ?? Self.extractText(from: payload["byline"])
            ?? Self.extractText(from: payload["artist"])
            ?? Self.extractText(from: payload["artistsText"])
            ?? Self.extractText(from: payload["channelName"])
            ?? Self.extractArtists(from: payload["artists"])
            ?? Self.extractFlexSubtitle(from: payload)
            ?? ""

        self.rank = Self.extractRank(from: payload) ?? "0"
        self.thumbnailURL = Self.extractThumbnailURL(from: payload)

        self.viewCount = Self.extractText(from: payload["viewCountText"])
            ?? Self.extractText(from: payload["viewCount"])
            ?? Self.extractText(from: payload["viewsText"])

        self.change = Self.extractChange(from: payload)
    }

    private static func unwrapAnalyticsPayload(_ data: [String: Any]) -> [String: Any] {
        let modelKeys = [
            "musicAnalyticsTrackViewModel",
            "musicAnalyticsVideoViewModel",
            "musicAnalyticsArtistViewModel"
        ]
        for key in modelKeys {
            if let nested = data[key] as? [String: Any] {
                return nested
            }
        }
        return data
    }

    private static func extractID(from data: [String: Any]) -> String? {
        if let videoId = data["videoId"] as? String {
            return videoId
        }
        if let encryptedVideoID = data["encryptedVideoId"] as? String {
            return encryptedVideoID
        }
        if let externalVideoID = data["atvExternalVideoId"] as? String {
            return externalVideoID
        }
        if let channelId = data["browseId"] as? String {
            return channelId
        }
        if let externalChannelID = data["externalChannelId"] as? String {
            return externalChannelID
        }
        if let id = data["id"] as? String {
            return id
        }
        if let entityID = data["entityId"] as? String {
            return entityID
        }
        if let nav = data["navigationEndpoint"] as? [String: Any],
           let watch = nav["watchEndpoint"] as? [String: Any],
           let vid = watch["videoId"] as? String {
            return vid
        }
        if let nav = data["navigationEndpoint"] as? [String: Any],
           let browse = nav["browseEndpoint"] as? [String: Any],
           let browseID = browse["browseId"] as? String {
            return browseID
        }
        return nil
    }

    private static func extractText(from value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let intValue = value as? Int {
            return String(intValue)
        }
        if let dict = value as? [String: Any] {
            if let simpleText = dict["simpleText"] as? String {
                return simpleText
            }
            if let runs = dict["runs"] as? [[String: Any]] {
                let joined = runs.compactMap { $0["text"] as? String }.joined()
                let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let text = dict["text"] as? String {
                return text
            }
            if let text = dict["name"] as? String {
                return text
            }
        }
        return nil
    }

    private static func extractArtists(from value: Any?) -> String? {
        guard let artists = value as? [[String: Any]] else { return nil }
        let names = artists.compactMap { artist in
            Self.extractText(from: artist["name"]) ?? Self.extractText(from: artist["text"])
        }
        if names.isEmpty { return nil }
        return names.joined(separator: ", ")
    }

    private static func extractFlexSubtitle(from data: [String: Any]) -> String? {
        guard let flex = data["flexColumns"] as? [[String: Any]], flex.count > 1,
              let textData = (flex[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] else {
            return nil
        }
        return Self.extractText(from: textData)
    }

    private static func extractRank(from data: [String: Any]) -> String? {
        if let rank = Self.extractText(from: data["rank"]) {
            return rank
        }
        if let rank = Self.extractText(from: data["chartRank"]) {
            return rank
        }
        if let chartEntryMetadata = data["chartEntryMetadata"] as? [String: Any] {
            if let currentPosition = chartEntryMetadata["currentPosition"] as? Int {
                return String(currentPosition)
            }
            if let currentPosition = chartEntryMetadata["currentPosition"] as? String {
                return currentPosition
            }
        }
        if let indexCol = (data["customIndexColumn"] as? [String: Any])?["musicCustomIndexColumnRenderer"] as? [String: Any],
           let textData = indexCol["text"] {
            return Self.extractText(from: textData)
        }
        return nil
    }

    private static func extractThumbnailURL(from data: [String: Any]) -> URL? {
        let candidates: [Any?] = [
            data["thumbnailDetails"],
            data["thumbnail"],
            data["musicThumbnailRenderer"],
            data["thumbnails"]
        ]

        for candidate in candidates {
            if let url = thumbnailURL(from: candidate) {
                return url
            }
        }

        return nil
    }

    private static func thumbnailURL(from value: Any?) -> URL? {
        if let thumbs = value as? [[String: Any]],
           let urlString = thumbs.last?["url"] as? String {
            return URL(string: urlString)
        }

        if let dict = value as? [String: Any] {
            if let thumbs = dict["thumbnails"] as? [[String: Any]],
               let urlString = thumbs.last?["url"] as? String {
                return URL(string: urlString)
            }

            if let nested = dict["thumbnail"] {
                return thumbnailURL(from: nested)
            }

            if let nested = dict["musicThumbnailRenderer"] {
                return thumbnailURL(from: nested)
            }
        }

        return nil
    }

    private static func extractChange(from data: [String: Any]) -> String? {
        if let explicit = Self.extractText(from: data["change"]) ?? Self.extractText(from: data["chartChangeText"]) {
            return explicit
        }

        guard let metadata = data["chartEntryMetadata"] as? [String: Any],
              let current = metadata["currentPosition"] as? Int,
              let previous = metadata["previousPosition"] as? Int else {
            return nil
        }

        if previous <= 0 {
            return "NEW"
        }

        let delta = previous - current
        if delta > 0 {
            return "+\(delta)"
        }
        if delta < 0 {
            return "\(delta)"
        }
        return "0"
    }
}

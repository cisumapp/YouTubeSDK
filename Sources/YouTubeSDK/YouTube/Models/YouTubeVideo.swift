//
//  YouTubeVideo.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 26/12/25.
//

import Foundation

public struct YouTubeVideo: Decodable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let viewCount: String
    public let author: String
    public let channelId: String
    public let description: String
    public let lengthInSeconds: String
    public let thumbnailURL: String?
    
    // The new Stream Data
    public var streamingData: StreamingData?
    
    public let captions: [CaptionTrack]?
    
    enum CodingKeys: String, CodingKey {
        case videoDetails
        case streamingData
    }
    
    enum VideoDetailsKeys: String, CodingKey {
        case videoId, title, viewCount, author, channelId
        case shortDescription, thumbnail
        case lengthInSeconds = "lengthSeconds"
    }
    
    enum ThumbnailKeys: String, CodingKey {
        case thumbnails
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // 1. Decode Details
        let details = try container.nestedContainer(keyedBy: VideoDetailsKeys.self, forKey: .videoDetails)
        self.id = try details.decode(String.self, forKey: .videoId)
        self.title = try details.decode(String.self, forKey: .title)
        self.viewCount = try details.decodeIfPresent(String.self, forKey: .viewCount) ?? "0"
        self.author = try details.decodeIfPresent(String.self, forKey: .author) ?? "Unknown"
        self.channelId = try details.decodeIfPresent(String.self, forKey: .channelId) ?? ""
        self.description = try details.decodeIfPresent(String.self, forKey: .shortDescription) ?? ""
        self.lengthInSeconds = try details.decodeIfPresent(String.self, forKey: .lengthInSeconds) ?? "0"
        
        // Thumbnail parsing
        if let thumbContainer = try? details.nestedContainer(keyedBy: ThumbnailKeys.self, forKey: .thumbnail),
           let thumbs = try? thumbContainer.decode([Thumbnail].self, forKey: .thumbnails) {
            self.thumbnailURL = thumbs.last?.url // Get the largest one
        } else {
            self.thumbnailURL = nil
        }
        
        // 2. Decode Streams
        self.streamingData = try container.decodeIfPresent(StreamingData.self, forKey: .streamingData)
        
        // Manual Parsing for Captions (Nested deep in playerCaptionsTracklistRenderer)
        // Usually found in the root dictionary, not videoDetails.
        // Since we are inside a specific container structure, we might need a manual init or helper.
        // For simplicity, let's assume we parse it manually in the Client or use optional chaining in init(from data).
        
        self.captions = nil
    }
    
    /// Returns the HLS URL if available (Best for AVPlayer).
    public var hlsURL: URL? {
        guard let urlString = streamingData?.hlsManifestUrl else { return nil }
        return URL(string: urlString)
    }
    
    /// Returns the highest quality audio-only stream (m4a/opus).
    public var bestAudioStream: Stream? {
        return streamingData?.adaptiveFormats
            .filter { $0.isAudioOnly }
            .sorted { $0.bitrate > $1.bitrate } // Highest bitrate first
            .first
    }
    
    /// Returns the best muxed video (Video + Audio combined).
    /// usually capped at 720p by YouTube, but easiest to play.
    public var bestMuxedStream: Stream? {
        return streamingData?.formats
            .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
            .first
    }
}

// Simple Helper for Thumbnails
private struct Thumbnail: Decodable {
    let url: String
    let width: Int
    let height: Int
}

public struct CaptionTrack: Decodable, Sendable {
    public let baseUrl: String
    public let name: String
    public let languageCode: String
}

public extension YouTubeVideo {
    /// Manual Initializer for Search Results (videoRenderer)
    init?(from data: [String: Any]) {
        guard let id = data["videoId"] as? String else { return nil }
        self.id = id
        
        // Title
        if let titleData = data["title"] as? [String: Any],
           let runs = titleData["runs"] as? [[String: Any]],
           let text = runs.first?["text"] as? String {
            self.title = text
        } else if let simple = (data["title"] as? [String: Any])?["simpleText"] as? String {
            self.title = simple
        } else {
            self.title = "Unknown"
        }
        
        // View Count
        if let viewData = data["viewCountText"] as? [String: Any],
           let simple = viewData["simpleText"] as? String {
            self.viewCount = simple
        } else if let shortViewData = data["shortViewCountText"] as? [String: Any],
                  let simple = shortViewData["simpleText"] as? String {
            self.viewCount = simple
        } else {
            self.viewCount = "0"
        }
        
        // Author/Channel (ownerText for standard videoRenderer, byline for compact/videoWithContext)
        let bylineRuns =
            (data["ownerText"] as? [String: Any])?["runs"] as? [[String: Any]] ??
            (data["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]] ??
            (data["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]
        
        if let runs = bylineRuns,
           let name = runs.first?["text"] as? String {
             self.author = name
             let nav = runs.first?["navigationEndpoint"] as? [String: Any]
             self.channelId = (nav?["browseEndpoint"] as? [String: Any])?["browseId"] as? String ?? ""
         } else {
             self.author = "Unknown"
             self.channelId = ""
         }
        
        // Thumbnail
        if let thumbDetails = data["thumbnail"] as? [String: Any],
           let thumbs = thumbDetails["thumbnails"] as? [[String: Any]],
           let url = thumbs.last?["url"] as? String {
            self.thumbnailURL = url
        } else {
            self.thumbnailURL = nil
        }
        
        // Length
        if let lengthData = data["lengthText"] as? [String: Any],
           let simple = lengthData["simpleText"] as? String {
            self.lengthInSeconds = simple // Keep as string "3:45"
        } else {
            self.lengthInSeconds = ""
        }
        
        self.description = ""
        self.streamingData = nil // Search results don't have streams
        
        // Extract Captions
        var tracks: [CaptionTrack] = []
        if let captionsData = data["captions"] as? [String: Any],
           let playerCaptions = captionsData["playerCaptionsTracklistRenderer"] as? [String: Any],
           let trackList = playerCaptions["captionTracks"] as? [[String: Any]] {
            
            for track in trackList {
                if let url = track["baseUrl"] as? String,
                   let nameData = track["name"] as? [String: Any],
                   let name = (nameData["simpleText"] as? String) ?? (nameData["runs"] as? [[String: Any]])?.first?["text"] as? String,
                   let lang = track["languageCode"] as? String {
                    tracks.append(CaptionTrack(baseUrl: url, name: name, languageCode: lang))
                }
            }
        }
        self.captions = tracks
    }
}

public extension YouTubeVideo {
    var requiresDeciphering: Bool {
        // If we have no HLS and the best streams have no URL but have a cipher
        guard hlsURL == nil else { return false }
        return streamingData?.adaptiveFormats.first?.url == nil && streamingData?.adaptiveFormats.first?.signatureCipher != nil
    }
}

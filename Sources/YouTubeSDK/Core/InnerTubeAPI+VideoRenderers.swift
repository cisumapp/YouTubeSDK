import Foundation
import os

private let tubeLog = Logger(subsystem: appSubsystem, category: "InnerTube")

// MARK: - InternalVideo renderer parsers

extension InnerTubeAPI {
    // MARK: - Testing hooks

    /// Internal accessor so unit tests can exercise the JSON parser without a live network.
    func parseInternalVideoGroupForTesting(_ json: [String: Any], title: String?) throws -> InternalVideoGroup {
        try parseInternalVideoGroup(from: json, title: title)
    }

    /// Internal accessor so unit tests can exercise the multi-shelf home row parser without a live network.
    func parseInternalVideoGroupRowsForTesting(_ json: [String: Any]) -> [InternalVideoGroup] {
        parseInternalVideoGroupRows(from: json)
    }

    // MARK: - Multi-shelf home row parser

    /// Walks the JSON looking for `richShelfRenderer` sections (YouTube home feed).
    /// Each shelf becomes a InternalVideoGroup with layout == .row.
    /// If no shelves are found, falls back to the flat parser.
    func parseInternalVideoGroupRows(from json: [String: Any]) -> [InternalVideoGroup] {
        var rows: [InternalVideoGroup] = []
        var continuationToken: String? = nil

        // Renderer keys that are known ad/promoted slots — skip silently.
        let adRendererKeys: Set = [
            "adSlotRenderer", "adRenderer", "promotedSparklesInternalVideoRenderer",
            "promotedInternalVideoRenderer", "adBreakServiceRenderer",
            "movingThumbnailRenderer",
        ]

        func dumpJSON(_ obj: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  let str = String(data: data, encoding: .utf8) else { return "<unserializable>" }
            // Truncate to avoid flooding the log
            return str.count > 2000 ? String(str.prefix(2000)) + "\n...(truncated)" : str
        }

        func walkShelfContents(_ obj: Any, depth: Int = 0) -> [InternalVideo] {
            guard depth < 50 else {
                tubeLog.warning("walkShelfContents: depth limit (50) reached — skipping subtree")
                return []
            }
            var videos: [InternalVideo] = []
            if let dict = obj as? [String: Any] {
                if let vr = dict["videoRenderer"] as? [String: Any], let v = parseInternalVideoRenderer(vr) {
                    videos.append(v)
                } else if let ri = dict["richItemRenderer"] as? [String: Any],
                          let content = ri["content"] as? [String: Any]
                {
                    if let vr = content["videoRenderer"] as? [String: Any],
                       let v = parseInternalVideoRenderer(vr)
                    {
                        videos.append(v)
                    } else if let reel = content["reelItemRenderer"] as? [String: Any],
                              let v = parseReelItemRenderer(reel)
                    {
                        videos.append(v)
                    } else {
                        let contentKeys = content.keys.sorted()
                        let isAd = contentKeys.contains(where: { adRendererKeys.contains($0) })
                        if isAd {
                            tubeLog.debug("walkShelfContents: skipping ad richItemRenderer keys=\(contentKeys, privacy: .public)")
                        } else {
                            tubeLog.notice("walkShelfContents: unrecognised richItemRenderer — add key to adRendererKeys if it is an ad\nkeys=\(contentKeys, privacy: .public)\nJSON=\(dumpJSON(content), privacy: .public)")
                            for value in content.values {
                                videos += walkShelfContents(value, depth: depth + 1)
                            }
                        }
                    }
                } else {
                    let dictKeys = dict.keys.sorted()
                    let isAd = dictKeys.contains(where: { adRendererKeys.contains($0) })
                    if isAd {
                        tubeLog.debug("walkShelfContents: skipping ad renderer keys=\(dictKeys, privacy: .public)")
                    } else {
                        for value in dict.values {
                            videos += walkShelfContents(value, depth: depth + 1)
                        }
                    }
                }
            } else if let arr = obj as? [Any] {
                for item in arr {
                    videos += walkShelfContents(item, depth: depth + 1)
                }
            }
            return videos
        }

        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else {
                tubeLog.warning("parseHomeSections: walk depth limit (50) reached — skipping subtree")
                return
            }
            if let dict = obj as? [String: Any] {
                if let shelf = dict["richShelfRenderer"] as? [String: Any] {
                    let title = (shelf["title"] as? [String: Any]).flatMap { extractText($0) }
                    let videos = walkShelfContents(shelf["contents"] as Any)
                    if !videos.isEmpty {
                        rows.append(InternalVideoGroup(title: title, videos: videos, layout: .row))
                    }
                    return
                }
                if let shelf = dict["reelShelfRenderer"] as? [String: Any] {
                    let title = (shelf["title"] as? [String: Any]).flatMap { extractText($0) }
                    let videos = walkShelfContents(shelf["items"] as Any)
                    if !videos.isEmpty {
                        rows.append(InternalVideoGroup(title: title, videos: videos, layout: .row))
                    }
                    return
                }
                if let contItem = dict["continuationItemRenderer"] as? [String: Any],
                   let contEndpoint = contItem["continuationEndpoint"] as? [String: Any],
                   let contCmd = contEndpoint["continuationCommand"] as? [String: Any],
                   let ct = contCmd["token"] as? String
                {
                    continuationToken = ct
                    return
                }
                // Log any richSectionRenderer whose inner content is not a richShelfRenderer
                // (ads and promos often appear as richSectionRenderer wrapping a non-shelf renderer)
                if let section = dict["richSectionRenderer"] as? [String: Any],
                   let content = section["content"] as? [String: Any]
                {
                    let contentKeys = content.keys.sorted()
                    let isAd = contentKeys.contains(where: { adRendererKeys.contains($0) })
                    if isAd {
                        tubeLog.debug("walk: skipping ad richSectionRenderer content keys=\(contentKeys, privacy: .public)")
                    } else if !contentKeys.contains("richShelfRenderer") {
                        tubeLog.notice("walk: unrecognised richSectionRenderer — add key to adRendererKeys if it is an ad\nkeys=\(contentKeys, privacy: .public)\nJSON=\(dumpJSON(content), privacy: .public)")
                        for value in dict.values {
                            walk(value, depth: depth + 1)
                        }
                    } else {
                        for value in dict.values {
                            walk(value, depth: depth + 1)
                        }
                    }
                    return
                }
                for value in dict.values {
                    walk(value, depth: depth + 1)
                }
            } else if let arr = obj as? [Any] {
                for item in arr {
                    walk(item, depth: depth + 1)
                }
            }
        }

        walk(json)

        if rows.isEmpty {
            // No shelves found — fall back to flat parse
            if let flat = try? parseInternalVideoGroup(from: json, title: BrowseSection.SectionType.home.defaultTitle) {
                return [flat]
            }
        } else if let token = continuationToken {
            // Attach continuation to the last row so BrowseViewModel can paginate
            rows[rows.count - 1].nextPageToken = token
        }

        return rows
    }

    // MARK: - Flat video group parser

    func parseInternalVideoGroup(from json: [String: Any], title: String?) throws -> InternalVideoGroup {
        var videos: [InternalVideo] = []
        var nextPageToken: String? = nil
        // Tracks the approximate watched/published date from section group headers.
        // History (and similar sections) use itemSectionRenderer with a header title
        // like "Today", "Yesterday", "This week" that is the closest available date
        // when the tile metadata lines contain no relative date string.
        var currentSectionDate: Date? = nil

        /// Walk the renderer tree to find videoRenderers and continuationItemRenderers.
        /// Handles WEB (videoRenderer, richItemRenderer, compactInternalVideoRenderer),
        /// WEB grid (gridInternalVideoRenderer), and TVHTML5 tileRenderer (subs/history/home on TV client).
        /// Matches Android MediaServiceCore ItemWrapper renderer dispatch order.
        func walk(_ obj: Any, depth: Int = 0) {
            guard depth < 50 else {
                tubeLog.warning("parseInternalVideoGroup: walk depth limit (50) reached — skipping subtree")
                return
            }
            if let dict = obj as? [String: Any] {
                // TVHTML5 gridRenderer stores its continuation in
                // gridRenderer.continuations[0].nextContinuationData.continuation.
                // Check this independently of the renderer dispatch below so we still
                // recurse into gridRenderer.items to collect the video tiles.
                if let continuations = dict["continuations"] as? [[String: Any]],
                   let token = continuations.first
                   .flatMap({ $0["nextContinuationData"] as? [String: Any] })
                   .flatMap({ $0["continuation"] as? String })
                {
                    nextPageToken = token
                }

                // TVHTML5 History groups tiles under itemSectionRenderer with a date
                // header ("Today", "Yesterday", "This week", …). Capture that header
                // and apply it as a fallback publishedAt for tiles with no explicit date.
                if let sectionRenderer = dict["itemSectionRenderer"] as? [String: Any] {
                    let prevDate = currentSectionDate
                    if let header = sectionRenderer["header"] as? [String: Any] {
                        let headerTitle = extractSectionTitle(from: header)
                        currentSectionDate = headerTitle.flatMap { parseSectionDate($0) }
                        tubeLog.debug("parseInternalVideoGroup: section '\(headerTitle ?? "nil", privacy: .public)' → date=\(currentSectionDate != nil ? "yes" : "nil", privacy: .public)")
                    }
                    walk(sectionRenderer["contents"] as Any, depth: depth + 1)
                    currentSectionDate = prevDate
                    return
                }

                if let renderer = dict["tileRenderer"] as? [String: Any] {
                    // TVHTML5 client (subs, history, home) — Android ItemWrapper.tileRenderer
                    if var v = parseTileRenderer(renderer) {
                        if v.publishedAt == nil { v.publishedAt = currentSectionDate }
                        videos.append(v)
                    }
                } else if let renderer = dict["videoRenderer"] as? [String: Any] {
                    if let v = parseInternalVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["gridInternalVideoRenderer"] as? [String: Any] {
                    if let v = parseInternalVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["reelItemRenderer"] as? [String: Any] {
                    if let v = parseReelItemRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["richItemRenderer"] as? [String: Any],
                          let content = renderer["content"] as? [String: Any]
                {
                    if let videoRenderer = content["videoRenderer"] as? [String: Any] {
                        if let v = parseInternalVideoRenderer(videoRenderer) { videos.append(v) }
                    } else if let reelRenderer = content["reelItemRenderer"] as? [String: Any] {
                        if let v = parseReelItemRenderer(reelRenderer) { videos.append(v) }
                    } else if let lockup = content["lockupViewModel"] as? [String: Any] {
                        // WEB home v2: richItemRenderer wraps lockupViewModel
                        if let v = parseLockupViewModel(lockup) { videos.append(v) }
                    } else if let contItem = content["continuationItemRenderer"] as? [String: Any],
                              let endpoint = contItem["continuationEndpoint"] as? [String: Any],
                              let command = endpoint["continuationCommand"] as? [String: Any],
                              let token = command["token"] as? String
                    {
                        // Continuation token nested inside richItemRenderer
                        nextPageToken = token
                    } else {
                        for value in content.values {
                            walk(value, depth: depth + 1)
                        }
                    }
                } else if let renderer = dict["compactInternalVideoRenderer"] as? [String: Any] {
                    if let v = parseInternalVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["playlistInternalVideoRenderer"] as? [String: Any] {
                    // WEB browse response for VL<playlistId> — playlist video items
                    // BUG-012 fix: use parsePlaylistInternalVideoRenderer instead of parseInternalVideoRenderer
                    // so shortBylineText/shortViewCountText fields are read correctly.
                    if let v = parsePlaylistInternalVideoRenderer(renderer) { videos.append(v) }
                } else if let renderer = dict["lockupViewModel"] as? [String: Any] {
                    // WEB home v2 (LockupItem in Android) — lockupViewModel
                    if let v = parseLockupViewModel(renderer) { videos.append(v) }
                } else if let contItem = dict["continuationItemRenderer"] as? [String: Any],
                          let endpoint = contItem["continuationEndpoint"] as? [String: Any],
                          let command = endpoint["continuationCommand"] as? [String: Any],
                          let token = command["token"] as? String
                {
                    nextPageToken = token
                } else {
                    for value in dict.values {
                        walk(value, depth: depth + 1)
                    }
                }
            } else if let arr = obj as? [Any] {
                for item in arr {
                    walk(item, depth: depth + 1)
                }
            }
        }

        walk(json)
        let shortsCount = videos.count(where: { $0.isShort })
        tubeLog.notice("parseInternalVideoGroup '\(title ?? "nil", privacy: .public)' → \(videos.count, privacy: .public) videos (\(videos.count - shortsCount, privacy: .public) regular, \(shortsCount, privacy: .public) shorts), nextPage=\(nextPageToken != nil ? "yes" : "no", privacy: .public)")
        return InternalVideoGroup(title: title, videos: videos, nextPageToken: nextPageToken)
    }

    // MARK: – TVHTML5 tileRenderer parser (Android TileItem methodology)

    // Mirrors: TileItem.getInternalVideoId(), getTitle(), getThumbnails(), getBadgeText(), getChannelId()
    private func parseTileRenderer(_ tile: [String: Any]) -> InternalVideo? {
        // Only parse video tiles — require the content type to be explicitly set.
        // Tiles with nil or non-video contentType (e.g. ads with customData/onFirstVisibleCommand)
        // are silently dropped. Android: TILE_CONTENT_TYPE_VIDEO
        // Also accept TILE_CONTENT_TYPE_REEL: FEshorts TVHTML5 response uses this type for
        // Short videos. Silently dropping all REEL tiles is why the Shorts row shows 0 results
        // from the dedicated FEshorts browse (only subs tiles, which are TILE_CONTENT_TYPE_VIDEO,
        // survive). Log unrecognised types so future renderer changes can be diagnosed.
        let contentType = tile["contentType"] as? String
        switch contentType {
        case "TILE_CONTENT_TYPE_VIDEO", "TILE_CONTENT_TYPE_REEL":
            break // accepted
        default:
            if let ct = contentType {
                tubeLog.notice("parseTileRenderer: dropping tile contentType=\(ct, privacy: .public)")
            }
            return nil
        }

        // Newer TVHTML5 history/subs responses sometimes nest it under innertubeCommand, or use
        // navigationEndpoint instead of onSelectCommand — try all three paths so regular history
        // videos are not silently dropped (leaving only reelItemRenderer Shorts visible).
        let onSelectCommand = tile["onSelectCommand"] as? [String: Any]
        let navigationEndpoint = tile["navigationEndpoint"] as? [String: Any]
        // videoId resolution order (most to least common in TVHTML5 history/subs responses):
        // 1. onSelectCommand.watchEndpoint.videoId              — classic path
        // 2. onSelectCommand.reelWatchEndpoint.videoId          — Shorts in TV subs/history feed
        // 3. onSelectCommand.innertubeCommand.watchEndpoint.videoId — newer TV variant
        // 4. onSelectCommand.innertubeCommand.reelWatchEndpoint.videoId — nested Shorts variant
        // 5. navigationEndpoint.watchEndpoint.videoId           — another TV variant
        // 6. navigationEndpoint.reelWatchEndpoint.videoId       — nav-level Shorts variant
        // 7. tile.contentId                                     — confirmed by live log: TVHTML5
        //    history tiles with commandExecutorCommand store the id directly here
        let reelWatchEndpoint: [String: Any]? = {
            if let ep = onSelectCommand?["reelWatchEndpoint"] as? [String: Any] { return ep }
            if let inner = onSelectCommand?["innertubeCommand"] as? [String: Any],
               let ep = inner["reelWatchEndpoint"] as? [String: Any] { return ep }
            if let ep = navigationEndpoint?["reelWatchEndpoint"] as? [String: Any] { return ep }
            if let inner = navigationEndpoint?["innertubeCommand"] as? [String: Any],
               let ep = inner["reelWatchEndpoint"] as? [String: Any] { return ep }
            return nil
        }()
        let watchEndpoint: [String: Any]? = {
            if let ep = onSelectCommand?["watchEndpoint"] as? [String: Any] { return ep }
            if let inner = onSelectCommand?["innertubeCommand"] as? [String: Any],
               let ep = inner["watchEndpoint"] as? [String: Any] { return ep }
            if let ep = navigationEndpoint?["watchEndpoint"] as? [String: Any] { return ep }
            return nil
        }()
        guard let videoId = reelWatchEndpoint?["videoId"] as? String
            ?? watchEndpoint?["videoId"] as? String
            ?? (tile["contentId"] as? String)
        else {
            return nil
        }

        // title: metadata.tileMetadataRenderer.title — Android: TileItem.getTitle()
        let tileMetadata = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any]
        let title = (tileMetadata?["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""

        // channelTitle: first line of tileMetadataRenderer.lines[0].lineRenderer.items[0].lineItemRenderer.text
        // Android TileItem.getUserName() = null, but we attempt best-effort extraction from lines
        let channelTitle: String = {
            guard let lines = tileMetadata?["lines"] as? [[String: Any]],
                  let firstLine = lines.first,
                  let lineRenderer = firstLine["lineRenderer"] as? [String: Any],
                  let items = lineRenderer["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let lineItemRenderer = firstItem["lineItemRenderer"] as? [String: Any],
                  let text = lineItemRenderer["text"] as? [String: Any]
            else { return "" }
            return extractText(text) ?? ""
        }()

        // channelId: watchEndpoint.channelId (primary) or onSelectCommand.browseEndpoint.browseId (secondary)
        // Fallback: extract @handle from onLongPressCommand.showMenuCommand.subtitle.simpleText
        // TV client subtitle format: "ChannelName • @handle" — YouTube browse API accepts @handle as browseId.
        let channelId: String? = {
            if let id = watchEndpoint?["channelId"] as? String { return id }
            if let id = (onSelectCommand?["browseEndpoint"] as? [String: Any])?["browseId"] as? String { return id }
            guard let showMenu = (tile["onLongPressCommand"] as? [String: Any])?["showMenuCommand"] as? [String: Any],
                  let subtitleText = (showMenu["subtitle"] as? [String: Any])?["simpleText"] as? String,
                  let atIndex = subtitleText.firstIndex(of: "@")
            else { return nil }
            return subtitleText[atIndex...]
                .components(separatedBy: .whitespacesAndNewlines)
                .first
                .map { String($0) }
        }()

        // thumbnail: header.tileHeaderRenderer.thumbnail.thumbnails — Android: TileItem.getThumbnails()
        let tileHeader = (tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any]
        let thumbnails = (tileHeader?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        // duration: header.tileHeaderRenderer.thumbnailOverlays[].thumbnailOverlayTimeStatusRenderer.text
        // Android: TileItem.getBadgeText()
        let overlays = tileHeader?["thumbnailOverlays"] as? [[String: Any]]
        let lengthText = overlays?.compactMap {
            ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any]).flatMap {
                ($0["text"] as? [String: Any]).flatMap { extractText($0) }
            }
        }.first
        let duration = lengthText.flatMap { parseDuration($0) }

        // percentWatched: thumbnailOverlays[].thumbnailOverlayResumePlaybackRenderer.percentDurationWatched
        // (same path as WEB, used for watch-again resume)
        let watchProgress: Double? = overlays?.compactMap {
            ($0["thumbnailOverlayResumePlaybackRenderer"] as? [String: Any])
                .flatMap { $0["percentDurationWatched"] as? Double }
        }.first.map { $0 / 100.0 }

        // isLive: thumbnailOverlay style == "LIVE" — Android: TileItem.isLive()
        let isLive = overlays?.contains {
            ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String == "LIVE"
        } ?? false

        // isShorts: style == "TILE_STYLE_YTLR_SHORTS" — Android: TileItem.isShorts()
        // Secondary signals (in priority order):
        //  • reelWatchEndpoint present on onSelectCommand/navigationEndpoint — definitive for Shorts
        //    tiles that carry neither TILE_STYLE_YTLR_SHORTS nor the overlay SHORTS style.
        //  • thumbnailOverlayTimeStatusRenderer.style == "SHORTS" — older TV subs feed fallback.
        //  • ustreamerConfig == "GgIIBQ==" — encodes proto(field3{field1:5}); value 5 is YouTube's
        //    CONTENT_TYPE_SHORTS hint embedded in the watchEndpoint. Observed on Shorts tiles that
        //    carry none of the other signals (TILE_STYLE_YTLR_DEFAULT, watchEndpoint not reel,
        //    landscape thumbnail). Regular videos carry value 1 ("GgIIAQ==") or omit the field.
        //  • Portrait thumbnail (height > width) — Shorts have 9:16 thumbnails; news/sports clips
        //    are always landscape 16:9, so this signal has zero false-positive risk for those.
        let isVerticalThumbnail = thumbnails?.contains {
            let w = ($0["width"] as? Int) ?? 0
            let h = ($0["height"] as? Int) ?? 0
            return h > w && w > 0
        } ?? false

        let ustreamerConfig = watchEndpoint?["ustreamerConfig"] as? String
        // GgIIBQ== encodes CONTENT_TYPE_SHORTS, but YouTube also attaches it to long-form
        // videos that appear in Shorts-adjacent shelves (subscription Shorts shelf, history,
        // home recommendations). Guard with a 180 s ceiling — the maximum YouTube Shorts
        // length — so only genuine Shorts are matched. When duration is unknown (nil),
        // default to trusting the signal.
        let isUstreamerShorts = ustreamerConfig == "GgIIBQ==" && (duration.map { $0 <= 180 } ?? true)

        let isShort = (tile["style"] as? String) == "TILE_STYLE_YTLR_SHORTS"
            || reelWatchEndpoint != nil
            || overlays?.contains {
                ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String == "SHORTS"
            } ?? false
            || isUstreamerShorts
            || isVerticalThumbnail

        if isUstreamerShorts {
            tubeLog.debug("tileRenderer isShort=true id=\(videoId, privacy: .public) signal=ustreamerConfig(\(ustreamerConfig ?? "", privacy: .public))")
        }

        // Diagnostic: log every TV-feed tile's Short signals so Console shows exactly
        // which signals are (or aren't) present, even for non-Short tiles.
        let overlayStyle = overlays?.compactMap {
            ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String
        }.first ?? "nil"
        let durationStr = duration.map { Int($0).description } ?? "nil"
        tubeLog.debug("tileRenderer id=\(videoId, privacy: .public) tileStyle=\(tile["style"] as? String ?? "nil", privacy: .public) reelEp=\(reelWatchEndpoint != nil, privacy: .public) overlayStyle=\(overlayStyle, privacy: .public) dur=\(durationStr, privacy: .public) vertThumb=\(isVerticalThumbnail, privacy: .public) ustreamerShorts=\(isUstreamerShorts, privacy: .public) → isShort=\(isShort, privacy: .public)")

        // publishedAt: best-effort from tileMetadata lines (second line may contain "2 years ago")
        let publishedAt: Date? = {
            guard let lines = tileMetadata?["lines"] as? [[String: Any]], lines.count > 1 else { return nil }
            for line in lines.dropFirst() {
                guard let items = (line["lineRenderer"] as? [String: Any])?["items"] as? [[String: Any]] else { continue }
                for item in items {
                    guard let text = (item["lineItemRenderer"] as? [String: Any])?["text"] as? [String: Any],
                          let str = extractText(text)
                    else { continue }
                    if let date = parseRelativeDate(str) { return date }
                }
            }
            return nil
        }()

        return InternalVideo(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            channelId: channelId,
            thumbnailURL: thumbURL,
            duration: duration,
            viewCount: {
                // BUG-011 fix: extract viewCount from tileMetadata lines instead of hardcoding nil.
                // The second line (index 1) typically contains "N views" or compact "1.2K views".
                guard let lines = tileMetadata?["lines"] as? [[String: Any]] else { return nil }
                for line in lines.dropFirst() {
                    guard let items = (line["lineRenderer"] as? [String: Any])?["items"] as? [[String: Any]] else { continue }
                    for item in items {
                        guard let text = (item["lineItemRenderer"] as? [String: Any])?["text"] as? [String: Any],
                              let str = extractText(text)
                        else { continue }
                        if let count = extractNumber(str) { return count }
                    }
                }
                return nil
            }(),
            publishedAt: publishedAt,
            isLive: isLive,
            isShort: isShort,
            watchProgress: watchProgress,
            badges: []
        )
    }

    // MARK: – WEB lockupViewModel parser (Android LockupItem methodology)

    // Mirrors: LockupItem.getInternalVideoId(), getTitle(), getThumbnails() in CommonHelper.kt
    private func parseLockupViewModel(_ lockup: [String: Any]) -> InternalVideo? {
        // videoId: rendererContext.commandContext.onTap.innertubeCommand.{watchEndpoint|reelWatchEndpoint}.videoId
        // Shorts use reelWatchEndpoint; regular videos use watchEndpoint.
        guard let rendererContext = lockup["rendererContext"] as? [String: Any],
              let commandContext = rendererContext["commandContext"] as? [String: Any],
              let onTap = commandContext["onTap"] as? [String: Any],
              let innertubeCommand = onTap["innertubeCommand"] as? [String: Any] else { return nil }

        let reelEndpoint = innertubeCommand["reelWatchEndpoint"] as? [String: Any]
        let watchEndpoint = innertubeCommand["watchEndpoint"] as? [String: Any]
        guard let videoId = reelEndpoint?["videoId"] as? String
            ?? watchEndpoint?["videoId"] as? String else { return nil }
        let isShort = reelEndpoint != nil
        if isShort {
            tubeLog.debug("lockupViewModel isShort=true id=\(videoId, privacy: .public) signal=reelWatchEndpoint")
        }

        // title: metadata.lockupMetadataViewModel.title
        // The field may be a TextViewModel ({"content": "…"}) in newer API responses,
        // or a legacy runs/simpleText dict handled by extractText.
        let lockupMeta = (lockup["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
        let title: String = {
            guard let titleDict = lockupMeta?["title"] as? [String: Any] else { return "" }
            return titleDict["content"] as? String ?? extractText(titleDict) ?? ""
        }()

        // channelTitle + channelId: metadata.lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows
        // The first row typically contains the channel name with a browseEndpoint for the channel.
        let metaContentVM = (lockupMeta?["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any]
        let metaRows = metaContentVM?["metadataRows"] as? [[String: Any]] ?? []

        let channelTitle: String = {
            guard let firstRow = metaRows.first,
                  let parts = firstRow["metadataParts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? [String: Any]
            else { return "" }
            return text["content"] as? String ?? extractText(text) ?? ""
        }()

        // channelId: watchEndpoint.channelId (primary) or reelWatchEndpoint.channelId or
        // lockupMetadataViewModel.metadata.contentMetadataViewModel.metadataRows[].metadataParts[]
        //   .text.commandRuns[].onTap.innertubeCommand.browseEndpoint.browseId (fallback)
        let channelId: String? = (watchEndpoint?["channelId"] as? String)
            ?? (reelEndpoint?["channelId"] as? String) ?? {
                for row in metaRows {
                    guard let parts = row["metadataParts"] as? [[String: Any]] else { continue }
                    for part in parts {
                        guard let text = part["text"] as? [String: Any],
                              let commandRuns = text["commandRuns"] as? [[String: Any]]
                        else { continue }
                        for run in commandRuns {
                            guard let cmd = (run["onTap"] as? [String: Any])?["innertubeCommand"] as? [String: Any],
                                  let browseId = (cmd["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
                                  browseId.hasPrefix("UC")
                            else { continue }
                            return browseId
                        }
                    }
                }
                return nil
            }()

        // thumbnail: contentImage.thumbnailViewModel.image.thumbnails
        let thumbVM = (lockup["contentImage"] as? [String: Any])?["thumbnailViewModel"] as? [String: Any]
        let thumbnails = (thumbVM?["image"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        let publishedAt: Date? = {
            for row in metaRows.dropFirst() {
                guard let parts = row["metadataParts"] as? [[String: Any]] else { continue }
                for part in parts {
                    guard let text = part["text"] as? [String: Any],
                          let str = text["content"] as? String ?? extractText(text)
                    else { continue }
                    if let date = parseRelativeDate(str) { return date }
                }
            }
            return nil
        }()

        return InternalVideo(
            id: videoId, title: title, channelTitle: channelTitle, channelId: channelId,
            thumbnailURL: thumbURL, duration: nil,
            viewCount: {
                // BUG-011 fix: extract viewCount from contentMetadataViewModel metadataRows.
                // Row index 1 (second row) often contains "N views" or compact count.
                for row in metaRows.dropFirst() {
                    guard let parts = row["metadataParts"] as? [[String: Any]] else { continue }
                    for part in parts {
                        guard let text = part["text"] as? [String: Any],
                              let str = text["content"] as? String ?? extractText(text)
                        else { continue }
                        if let count = extractNumber(str) { return count }
                    }
                }
                return nil
            }(),
            publishedAt: publishedAt,
            isLive: false, isShort: isShort, badges: []
        )
    }

    // MARK: – Shorts reelItemRenderer parser

    private func parseReelItemRenderer(_ r: [String: Any]) -> InternalVideo? {
        guard let videoId = r["videoId"] as? String else { return nil }
        let title = (r["headline"] as? [String: Any]).flatMap { extractText($0) } ?? ""
        let thumbnails = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        // channelTitle: ownerText or shortBylineText
        let channelTitle: String = (r["ownerText"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["shortBylineText"] as? [String: Any]).flatMap { extractText($0) }
            ?? ""

        // channelId: navigationEndpoint.reelWatchEndpoint.channelId (primary)
        // or ownerText/shortBylineText runs[0].navigationEndpoint.browseEndpoint.browseId (fallback)
        let channelId: String? = {
            if let channelId = (r["navigationEndpoint"] as? [String: Any])
                .flatMap({ ($0["reelWatchEndpoint"] as? [String: Any])?["channelId"] as? String })
            {
                return channelId
            }
            let sourceKey = r["ownerText"] != nil ? "ownerText" : "shortBylineText"
            guard let runs = (r[sourceKey] as? [String: Any])?["runs"] as? [[String: Any]],
                  let first = runs.first,
                  let nav = first["navigationEndpoint"] as? [String: Any],
                  let browse = nav["browseEndpoint"] as? [String: Any]
            else { return nil }
            return browse["browseId"] as? String
        }()

        return InternalVideo(
            id: videoId, title: title, channelTitle: channelTitle, channelId: channelId,
            thumbnailURL: thumbURL, duration: nil,
            viewCount: {
                // BUG-011 fix: extract viewCount from viewCountText (runs or simpleText).
                let vcText = (r["viewCountText"] as? [String: Any]).flatMap { extractText($0) }
                return vcText.flatMap { extractNumber($0) }
            }(),
            isLive: false, isShort: true, hasPortraitThumbnail: true, badges: []
        )
    }

    // MARK: – WEB videoRenderer parser

    func parseInternalVideoRenderer(_ r: [String: Any]) -> InternalVideo? {
        guard let videoId = r["videoId"] as? String else { return nil }
        let title = (r["title"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["headline"] as? [String: Any]).flatMap { extractText($0) }
            ?? ""
        let channelTitle = (r["ownerText"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["shortBylineText"] as? [String: Any]).flatMap { extractText($0) }
            ?? ""

        // channelId: ownerText (videoRenderer) or shortBylineText (gridInternalVideoRenderer)
        let channelId: String? = {
            let sourceKey = r["ownerText"] != nil ? "ownerText" : "shortBylineText"
            guard let runs = (r[sourceKey] as? [String: Any])?["runs"] as? [[String: Any]],
                  let first = runs.first,
                  let nav = first["navigationEndpoint"] as? [String: Any],
                  let browse = nav["browseEndpoint"] as? [String: Any]
            else { return nil }
            return browse["browseId"] as? String
        }()

        let thumbnails = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        // duration: lengthText (videoRenderer) or thumbnailOverlays[N].thumbnailOverlayTimeStatusRenderer.text (gridInternalVideoRenderer)
        let lengthText: String? = (r["lengthText"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["thumbnailOverlays"] as? [[String: Any]])?
            .compactMap { ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["text"] as? [String: Any] }
            .first.flatMap { extractText($0) }
        let duration = lengthText.flatMap { parseDuration($0) }

        let viewCountText = (r["viewCountText"] as? [String: Any]).flatMap { extractText($0) }
            // BUG-014 fix: fall back to shortViewCountText when viewCountText is absent (some locales/auth configs).
            ?? (r["shortViewCountText"] as? [String: Any]).flatMap { extractText($0) }
        let viewCount = viewCountText.flatMap { extractNumber($0) }
            // Further fallback: direct integer field (rare, but present in some compact API responses).
            ?? r["viewCount"] as? Int

        let isLive = (r["badges"] as? [[String: Any]])?.contains {
            (($0["metadataBadgeRenderer"] as? [String: Any])?["style"] as? String) == "BADGE_STYLE_TYPE_LIVE_NOW"
        } ?? false

        let isShort: Bool = {
            // Primary signal: reelWatchEndpoint in navigationEndpoint (home, search, most feeds)
            // Guard with duration ≤ 180 s: YouTube occasionally attaches reelWatchEndpoint to
            // regular videos (e.g. because they were also published as a Short). The duration
            // guard prevents those from being misclassified as Shorts. When duration is unknown
            // (nil) we trust the endpoint signal alone — Shorts with no parsed duration are
            // still Shorts.
            if let nav = r["navigationEndpoint"] as? [String: Any], nav["reelWatchEndpoint"] != nil {
                if duration.map({ $0 <= 180 }) ?? true { return true }
            }
            // Secondary signal: thumbnailOverlayTimeStatusRenderer.style == "SHORTS"
            // (subscriptions feed often omits reelWatchEndpoint and uses this style instead).
            // Guard with duration ≤ 180 s: regular videos can appear in Shorts-adjacent shelves
            // with this overlay style, causing false positives. Duration validation prevents
            // misclassification of videos like vkUokV3Xwp8. Mirrors the guard in parseTileRenderer.
            let hasShortOverlay = (r["thumbnailOverlays"] as? [[String: Any]])?.contains {
                ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String == "SHORTS"
            } ?? false
            if hasShortOverlay, (duration.map { $0 <= 180 } ?? true) { return true }
            // Tertiary signal: ustreamerConfig == "GgIIBQ==" — mirrors parseTileRenderer.
            // Catches compactInternalVideoRenderer Short tiles in TV subs/history feeds that omit both
            // reelWatchEndpoint and the overlay style.
            let watchEndpoint = (r["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any]
            let ustreamerConfig = watchEndpoint?["ustreamerConfig"] as? String
            if ustreamerConfig == "GgIIBQ==", (duration.map { $0 <= 180 } ?? true) { return true }
            // Quaternary signal: vertical thumbnail (height > width) — another parseTileRenderer mirror.
            let thumbnails = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
            return thumbnails?.contains {
                let w = ($0["width"] as? Int) ?? 0
                let h = ($0["height"] as? Int) ?? 0
                return h > w && w > 0
            } ?? false
        }()
        if isShort {
            let signal: String
            if let nav = r["navigationEndpoint"] as? [String: Any], nav["reelWatchEndpoint"] != nil {
                signal = "reelWatchEndpoint"
            } else {
                let hasShortOverlay = (r["thumbnailOverlays"] as? [[String: Any]])?.contains {
                    ($0["thumbnailOverlayTimeStatusRenderer"] as? [String: Any])?["style"] as? String == "SHORTS"
                } ?? false
                signal = hasShortOverlay ? "overlayStyle" : "ustreamerConfig/verticalThumb"
            }
            tubeLog.debug("videoRenderer isShort=true id=\(videoId, privacy: .public) signal=\(signal, privacy: .public) duration=\(Int(duration ?? -1))")
        }

        let badges = (r["badges"] as? [[String: Any]])?.compactMap {
            ($0["metadataBadgeRenderer"] as? [String: Any])?["label"] as? String
        } ?? []

        let watchProgress: Double? = (r["thumbnailOverlays"] as? [[String: Any]])?
            .compactMap { ($0["thumbnailOverlayResumePlaybackRenderer"] as? [String: Any])
                .flatMap { $0["percentDurationWatched"] as? Double }
            }
            .first.map { $0 / 100.0 }

        // Parse feed feedback tokens keyed by icon type from the video's menuRenderer.
        // All three actions share the /feedback endpoint — only the token differs.
        let feedbackTokens: [String: String] = {
            guard let menu = r["menu"] as? [String: Any],
                  let mr = menu["menuRenderer"] as? [String: Any],
                  let items = mr["items"] as? [[String: Any]]
            else { return [:] }
            var result: [String: String] = [:]
            for item in items {
                guard let svc = item["menuServiceItemRenderer"] as? [String: Any],
                      let endpoint = svc["serviceEndpoint"] as? [String: Any],
                      let token = (endpoint["feedbackEndpoint"] as? [String: Any])?["feedbackToken"] as? String,
                      let iconType = (svc["icon"] as? [String: Any])?["iconType"] as? String
                else { continue }
                result[iconType] = token
            }
            return result
        }()

        let publishedAt: Date? = (r["publishedTimeText"] as? [String: Any])
            .flatMap { extractText($0) }
            .flatMap { parseRelativeDate($0) }

        return InternalVideo(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            channelId: channelId,
            thumbnailURL: thumbURL,
            duration: duration,
            viewCount: viewCount,
            publishedAt: publishedAt,
            isLive: isLive,
            isShort: isShort,
            watchProgress: watchProgress,
            badges: badges,
            notInterestedToken: feedbackTokens["NOT_INTERESTED"],
            dontLikeToken: feedbackTokens["DISLIKE"],
            hideChannelToken: feedbackTokens["BLOCK_CHANNEL"]
        )
    }

    // MARK: – WEB playlistInternalVideoRenderer parser (BUG-012 fix)

    /// Playlist video items use shortBylineText/shortViewCountText instead of
    /// ownerText/viewCountText which parseInternalVideoRenderer expects.
    private func parsePlaylistInternalVideoRenderer(_ r: [String: Any]) -> InternalVideo? {
        guard let videoId = r["videoId"] as? String else { return nil }
        let title = (r["title"] as? [String: Any]).flatMap { extractText($0) } ?? ""

        // channelTitle: shortBylineText preferred; ownerText as fallback
        let channelTitle = (r["shortBylineText"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["ownerText"] as? [String: Any]).flatMap { extractText($0) }
            ?? ""

        // channelId: from shortBylineText or ownerText runs[0].navigationEndpoint.browseEndpoint.browseId
        let channelId: String? = {
            let sourceKey = r["shortBylineText"] != nil ? "shortBylineText" : "ownerText"
            guard let runs = (r[sourceKey] as? [String: Any])?["runs"] as? [[String: Any]],
                  let first = runs.first,
                  let nav = first["navigationEndpoint"] as? [String: Any],
                  let browse = nav["browseEndpoint"] as? [String: Any]
            else { return nil }
            return browse["browseId"] as? String
        }()

        let thumbnails = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbURL = thumbnails?.last.flatMap { $0["url"] as? String }.flatMap { URL(string: $0) }

        let lengthText = (r["lengthText"] as? [String: Any]).flatMap { extractText($0) }
        let duration = lengthText.flatMap { parseDuration($0) }

        // viewCount: shortViewCountText preferred; viewCountText as fallback; direct int last
        let viewCountText = (r["shortViewCountText"] as? [String: Any]).flatMap { extractText($0) }
            ?? (r["viewCountText"] as? [String: Any]).flatMap { extractText($0) }
        let viewCount = viewCountText.flatMap { extractNumber($0) } ?? r["viewCount"] as? Int

        let watchProgress: Double? = (r["thumbnailOverlays"] as? [[String: Any]])?
            .compactMap { ($0["thumbnailOverlayResumePlaybackRenderer"] as? [String: Any])
                .flatMap { $0["percentDurationWatched"] as? Double }
            }
            .first.map { $0 / 100.0 }

        let publishedAt: Date? = (r["publishedTimeText"] as? [String: Any])
            .flatMap { extractText($0) }
            .flatMap { parseRelativeDate($0) }

        return InternalVideo(
            id: videoId,
            title: title,
            channelTitle: channelTitle,
            channelId: channelId,
            thumbnailURL: thumbURL,
            duration: duration,
            viewCount: viewCount,
            publishedAt: publishedAt,
            isLive: false,
            isShort: false,
            watchProgress: watchProgress,
            badges: []
        )
    }
}

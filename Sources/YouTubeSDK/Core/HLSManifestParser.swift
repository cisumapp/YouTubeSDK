import Foundation

// MARK: - HLS Master Manifest Parser
//
// Parses an HLS master playlist (M3U8) and returns a map of stream height → variant URL.
// Extracted from PlaybackQualityManager.fetchHLSVariantURLs (task #133, SRP-1).
//
// On iOS/macOS the parser prefers the H.264 (avc1) variant when both HEVC and H.264
// are present at the same resolution. On tvOS the first-seen variant is kept as-is
// (tvOS hardware decoders handle HEVC efficiently with lower power consumption).

/// Parses `manifestText` as an HLS master playlist and returns a map of
/// stream height (e.g. 1080) → absolute variant playlist URL.
///
/// - Parameters:
///   - manifestText: The raw text content of the `.m3u8` master playlist.
///   - baseURL: Base URL used to resolve relative URIs in the manifest.
/// - Returns: Dictionary mapping height in pixels to the best variant URL for that height.
public func parseHLSMasterManifest(_ manifestText: String, baseURL: URL) -> [Int: URL] {
    var variants: [Int: URL] = [:]
    var variantIsH264: [Int: Bool] = [:]
    let lines = manifestText.components(separatedBy: .newlines)
    var pendingHeight: Int? = nil
    var pendingIsH264: Bool = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
            pendingHeight = nil
            pendingIsH264 = false

            if let range = trimmed.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression) {
                let match = String(trimmed[range])
                if let xIdx = match.firstIndex(of: "x"),
                   let height = Int(match[match.index(after: xIdx)...]) {
                    pendingHeight = height
                }
            }
            if let codecsRange = trimmed.range(of: #"CODECS="[^"]*""#, options: .regularExpression) {
                pendingIsH264 = trimmed[codecsRange].contains("avc1")
            }

        } else if !trimmed.hasPrefix("#"), !trimmed.isEmpty, let height = pendingHeight {
            let variantURL: URL?
            if trimmed.hasPrefix("http") {
                variantURL = URL(string: trimmed)
            } else {
                variantURL = URL(string: trimmed, relativeTo: baseURL).map { $0.absoluteURL }
            }

            if let resolvedURL = variantURL {
                if variants[height] == nil {
                    variants[height] = resolvedURL
                    variantIsH264[height] = pendingIsH264
                } else {
#if !os(tvOS)
                    // iOS/macOS: upgrade HEVC variant to H.264 if one arrives later.
                    if !(variantIsH264[height] ?? false) && pendingIsH264 {
                        variants[height] = resolvedURL
                        variantIsH264[height] = true
                    }
#endif
                }
            }
            pendingHeight = nil
            pendingIsH264 = false

        } else if trimmed.hasPrefix("#") {
            // Any tag other than #EXT-X-STREAM-INF resets pending state so
            // we don't accidentally attach a URI from a different entry.
            if pendingHeight != nil, !trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                pendingHeight = nil
                pendingIsH264 = false
            }
        }
    }

    return variants
}

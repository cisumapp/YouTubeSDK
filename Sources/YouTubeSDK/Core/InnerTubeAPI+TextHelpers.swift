import Foundation

// MARK: - Text extraction helpers

extension InnerTubeAPI {

    func extractText(_ dict: [String: Any]) -> String? {
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }

    func parseDuration(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return TimeInterval(parts[0] * 60 + parts[1])
        case 3: return TimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return nil
        }
    }

    /// Extracts the display title from an itemSectionRenderer header dict.
    func extractSectionTitle(from header: [String: Any]) -> String? {
        let rendererKeys = [
            "tileGroupHeaderRenderer",
            "itemSectionHeaderRenderer",
            "richSectionHeaderRenderer",
            "sectionHeaderRenderer",
        ]
        for key in rendererKeys {
            if let renderer = header[key] as? [String: Any],
               let titleObj = renderer["title"] as? [String: Any],
               let text = extractText(titleObj) {
                return text
            }
        }
        return nil
    }

    /// Maps a section label ("Today", "Yesterday", …) to an approximate Date.
    func parseSectionDate(_ title: String) -> Date? {
        let cal = Calendar.current
        let now = Date.now
        let startOfToday = cal.startOfDay(for: now)
        switch title.lowercased() {
        case "today":
            return startOfToday
        case "yesterday":
            return cal.date(byAdding: .day, value: -1, to: startOfToday)
        case "this week":
            return cal.date(byAdding: .day, value: -4, to: startOfToday)
        case "last week":
            return cal.date(byAdding: .day, value: -10, to: startOfToday)
        case "earlier this month":
            return cal.date(byAdding: .day, value: -15, to: startOfToday)
        case "this month":
            return cal.date(byAdding: .day, value: -7, to: startOfToday)
        case "last month":
            return cal.date(byAdding: .month, value: -1, to: startOfToday)
        default:
            return parseRelativeDate(title)
        }
    }

    func parseRelativeDate(_ text: String) -> Date? {
        let stripped = text
            .replacingOccurrences(of: #"^(Streamed|Premiered|Started)\s+"#, with: "", options: .regularExpression)
            .lowercased()
        let pattern = #"(\d+)\s+(second|minute|hour|day|week|month|year)s?\s+ago"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let valueRange = Range(match.range(at: 1), in: stripped),
              let unitRange = Range(match.range(at: 2), in: stripped),
              let value = Int(stripped[valueRange])
        else { return nil }
        let unit = String(stripped[unitRange])
        let seconds: TimeInterval
        switch unit {
        case "second": seconds = TimeInterval(value)
        case "minute": seconds = TimeInterval(value * 60)
        case "hour":   seconds = TimeInterval(value * 3_600)
        case "day":    seconds = TimeInterval(value * 86_400)
        case "week":   seconds = TimeInterval(value * 7 * 86_400)
        case "month":  seconds = TimeInterval(value * 30 * 86_400)
        case "year":   seconds = TimeInterval(value * 365 * 86_400)
        default:       return nil
        }
        return Date(timeIntervalSinceNow: -seconds)
    }

    func extractNumber(_ text: String) -> Int? {
        // Suffix path: extract leading decimal + K/M/B multiplier (e.g. "1.5K" → 1500)
        let pattern = #"([\d,]+(?:\.\d+)?)\s*([KkMmBb])\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let numRange = Range(match.range(at: 1), in: text),
           let suffixRange = Range(match.range(at: 2), in: text) {
            let numStr = text[numRange].replacingOccurrences(of: ",", with: "")
            if let value = Double(numStr) {
                let suffix = text[suffixRange].uppercased()
                let multiplier: Double
                switch suffix {
                case "K": multiplier = 1_000
                case "M": multiplier = 1_000_000
                case "B": multiplier = 1_000_000_000
                default:  multiplier = 1
                }
                return Int(value * multiplier)
            }
        }
        // Plain path: strip non-digits (handles commas in "1,234 views")
        let digits = text.replacingOccurrences(of: ",", with: "")
            .components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return digits.isEmpty ? nil : Int(digits)
    }
}

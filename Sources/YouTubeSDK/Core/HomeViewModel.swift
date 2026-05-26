import Foundation
import Observation
import os

private let homeLog = ViewModelLogger(category: "Home")

// MARK: - HomeViewModel
//
// Fetches Subscriptions and Recommended shelves in parallel
// to populate the Home tab's multi-section feed.

@MainActor
@Observable
public final class HomeViewModel {

    // MARK: - Section state

    public struct SectionState: Identifiable {
        public let section: BrowseSection
        public var videos: [InternalVideo] = []
        public var isLoading: Bool = true
        public var isLoadingMore: Bool = false
        public var hasFailed: Bool = false
        public var nextPageToken: String? = nil
        public var id: String { section.id }
    }

    // MARK: - State

    public private(set) var sections: [SectionState]
    /// Shorts fetched explicitly via FEshorts (TV home feed never includes them).
    public private(set) var shortsInternalVideos: [InternalVideo] = []
    /// Continuation token from the last FEshorts fetch; used by loadMoreShortsIfNeeded.
    private var shortsNextPageToken: String? = nil
    private var isLoadingMoreShorts: Bool = false
    public private(set) var isRefreshing: Bool = false
    /// Timestamp of the last successful load. Used for staleness checks.
    public private(set) var loadedAt: Date? = nil

    // MARK: - Shelf definitions (in display order)

    public static let shelfSections: [BrowseSection] = [
        BrowseSection(id: BrowseSection.SectionType.home.rawValue,          title: "Recommended",   type: .home),
        BrowseSection(id: BrowseSection.SectionType.subscriptions.rawValue, title: "Subscriptions", type: .subscriptions),
    ]

    /// Number of recommended videos inserted between each subscription video
    /// in the interleaved home feed.
    private static let interleaveRatio = 4

    /// `true` while either the recommended or subscriptions section is still on
    /// its initial load (no videos yet).  Used by the view to show a spinner.
    public var isLoadingAny: Bool {
        sections.contains { $0.isLoading }
    }

    /// A single interleaved video list that mixes recommended and subscription
    /// videos: one subscription video is inserted after every `interleaveRatio`
    /// recommended videos.  Subscription videos that duplicate an already-seen
    /// recommended ID are skipped.
    public var mergedInternalVideos: [InternalVideo] {
        let recState  = sections.first { $0.section.type == .home }
        let subState  = sections.first { $0.section.type == .subscriptions }
        let recs  = recState?.videos  ?? []
        let subs  = subState?.videos  ?? []

        guard !subs.isEmpty else {
            var seen = Set<String>()
            let deduped = recs.filter { seen.insert($0.id).inserted }
            if deduped.count != recs.count {
                homeLog.notice("mergedInternalVideos: recs-only dedup removed \(recs.count - deduped.count) duplicate(s) (raw=\(recs.count))")
            }
            return deduped
        }
        guard !recs.isEmpty else {
            var seen = Set<String>()
            let deduped = subs.filter { seen.insert($0.id).inserted }
            if deduped.count != subs.count {
                homeLog.notice("mergedInternalVideos: subs-only dedup removed \(subs.count - deduped.count) duplicate(s) (raw=\(subs.count))")
            }
            return deduped
        }

        let recIds = Set(recs.map(\.id))
        let uniqueSubs = subs.filter { !recIds.contains($0.id) }

        var result: [InternalVideo] = []
        result.reserveCapacity(recs.count + uniqueSubs.count)

        var subIndex = 0
        for (i, rec) in recs.enumerated() {
            result.append(rec)
            let slot = i + 1
            if slot % Self.interleaveRatio == 0, subIndex < uniqueSubs.count {
                result.append(uniqueSubs[subIndex])
                subIndex += 1
            }
        }
        // Append any remaining subscription videos after all recommended videos.
        if subIndex < uniqueSubs.count {
            result.append(contentsOf: uniqueSubs[subIndex...])
        }
        // Final safety-net dedup: prevents any remaining duplicate IDs from
        // reaching ForEach, which would cause SwiftUI to render blank cells.
        var seen = Set<String>()
        let deduped = result.filter { seen.insert($0.id).inserted }
        if deduped.count != result.count {
            homeLog.notice("mergedInternalVideos: final dedup removed \(result.count - deduped.count) duplicate(s) (subs+recs raw=\(result.count))")
        }
        return deduped
    }

    /// Non-Short videos from the interleaved home feed.
    /// Used by `homeShelves` to populate the main grid (Shorts are shown separately).
    public var homeRegularInternalVideos: [InternalVideo] { mergedInternalVideos.filter { !$0.isShort } }

    /// Short videos for the dedicated Shorts row.
    /// Sources (in priority order, deduplicated by video ID):
    ///  1. `shortsInternalVideos` — from the FEshorts browse (when the API works)
    ///  2. Subscriptions section shorts — pulled directly from the full subs list so
    ///     they are not lost to the home/subs interleave ratio in `mergedInternalVideos`
    ///  3. `mergedInternalVideos` shorts — catches any shorts from the home-rec feed
    public var homeShortsInternalVideos: [InternalVideo] {
        let subsShorts = sections.first { $0.section.type == .subscriptions }?.videos.filter { $0.isShort } ?? []
        var seen = Set<String>()
        return (shortsInternalVideos + subsShorts + mergedInternalVideos.filter { $0.isShort })
            .filter { seen.insert($0.id).inserted }
    }

    // MARK: - Dependencies

    private let api: any InnerTubeAPIProtocol
    private var loadTask: Task<Void, Never>?
    private var hideObserverTasks: [Task<Void, Never>] = []
    /// Tracks whether a non-nil auth token has been set. Used to distinguish a
    /// sign-in event (nil → non-nil) from a token refresh (non-nil → new non-nil)
    /// so that token refreshes during video playback do not trigger a feed reload.
    private var hasAuthToken: Bool = false

    public init(api: any InnerTubeAPIProtocol = InnerTubeAPI()) {
        self.api = api
        self.sections = Self.shelfSections.map { SectionState(section: $0) }
        observeFeedHideNotifications()
    }

    // MARK: - Feed hide handling

    private func observeFeedHideNotifications() {
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideInternalVideoFromFeed) {
                guard let self, let videoId = note.userInfo?["videoId"] as? String else { continue }
                self.removeInternalVideo(id: videoId)
            }
        })
        hideObserverTasks.append(Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .hideChannelFromFeed) {
                guard let self, let channelId = note.userInfo?["channelId"] as? String else { continue }
                self.removeChannel(id: channelId)
            }
        })
    }

    public func removeInternalVideo(id: String) {
        for i in sections.indices {
            sections[i].videos.removeAll { $0.id == id }
        }
    }

    public func removeChannel(id: String) {
        for i in sections.indices {
            sections[i].videos.removeAll { $0.channelId == id }
        }
    }

    // MARK: - Public API

    public func load() {
        loadTask?.cancel()
        loadedAt = nil
        isRefreshing = true
        shortsInternalVideos = []
        for i in sections.indices {
            sections[i].videos = []
            sections[i].isLoading = true
            sections[i].isLoadingMore = false
            sections[i].hasFailed = false
            sections[i].nextPageToken = nil
        }

        loadTask = Task {
            // Fetch shorts via FEshorts in parallel with the home/subs feed.
            // The TV home feed (FEwhat_to_watch) never includes a Shorts shelf.
            async let fetchedShortsResult: ([InternalVideo], String?) = HomeViewModel.fetchShortsInternalVideos(api: self.api)

            await withTaskGroup(of: (String, [InternalVideo], String?).self) { group in
                for state in sections {
                    let sectionId = state.id
                    let type = state.section.type
                    let api = self.api
                    group.addTask {
                        let (videos, token) = await HomeViewModel.fetchInternalVideos(type: type, api: api)
                        return (sectionId, videos, token)
                    }
                }
                for await (sectionId, videos, token) in group {
                    guard !Task.isCancelled else { break }
                    if let idx = sections.firstIndex(where: { $0.id == sectionId }) {
                        sections[idx].videos = videos
                        sections[idx].nextPageToken = token
                        sections[idx].isLoading = false
                        sections[idx].hasFailed = videos.isEmpty
                    }
                }
            }
            shortsInternalVideos = await fetchedShortsResult.0
            shortsNextPageToken = await fetchedShortsResult.1
            // Fill the initial threshold (6 iOS / 8 tvOS) quickly.
            // Further pages are loaded lazily as the user scrolls to the last card.
            await loadMoreShortsIfNeeded()
            isRefreshing = false
            loadedAt = Date()
            let merged = self.mergedInternalVideos
            let mergedShorts = merged.filter { $0.isShort }.count
            homeLog.notice("load complete: merged=\(merged.count) regular=\(merged.count - mergedShorts) mergedShorts=\(mergedShorts) shortsSection=\(shortsInternalVideos.count)")
        }
    }

    public func updateAuthToken(_ token: String?) async {
        let wasAuthenticated = hasAuthToken
        hasAuthToken = token != nil
        await api.setAuthToken(token)
        if token != nil && !wasAuthenticated {
            // Only reload on sign-in (nil → token). Token refreshes that happen
            // during video playback keep the same sign-in state and must not
            // wipe and reload the home feed.
            load()
        }
    }

    /// Refreshes both shelves if the last successful load was more than
    /// `threshold` seconds ago (default 15 min). No-op while loading.
    public func refreshIfStale(threshold: TimeInterval = 15 * 60) {
        guard !isRefreshing else { return }
        let age = loadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > threshold else { return }
        let ageDesc = age.isFinite ? "\(Int(age))s" : "never loaded"
        homeLog.notice("refreshIfStale: age=\(ageDesc) — reloading shelves")
        load()
    }

    // MARK: - Pagination

    public func loadMore(sectionId: String) {
        guard let idx = sections.firstIndex(where: { $0.id == sectionId }),
              let token = sections[idx].nextPageToken,
              !sections[idx].isLoadingMore,
              !sections[idx].isLoading else { return }
        sections[idx].isLoadingMore = true
        let type = sections[idx].section.type
        Task {
            let (newInternalVideos, nextToken) = await HomeViewModel.fetchMoreInternalVideos(type: type, token: token, api: api)
            if let idx = sections.firstIndex(where: { $0.id == sectionId }) {
                // Use a growing set so IDs that appear multiple times within
                // newInternalVideos itself (same page returning the same video twice)
                // are also caught — not just duplicates against existing videos.
                var seenIds = Set(sections[idx].videos.map(\.id))
                let deduplicated = newInternalVideos.filter { seenIds.insert($0.id).inserted }
                sections[idx].videos.append(contentsOf: deduplicated)
                // Re-sort after merging so videos from different pages remain in
                // strict newest-first order across pagination boundaries.
                if sections[idx].section.type == .subscriptions {
                    sections[idx].videos.sort { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                }
                sections[idx].nextPageToken = nextToken
                sections[idx].isLoadingMore = false
            }
        }
    }

    /// Called by the merged home feed when the user scrolls near the bottom.
    /// Pages both the recommended and subscriptions sections simultaneously so
    /// the interleaved list keeps growing evenly.
    public func loadMoreMerged() {
        for state in sections where state.section.type == .home || state.section.type == .subscriptions {
            loadMore(sectionId: state.id)
        }
    }

    /// Called by the view when the user scrolls to the last card in the Shorts row.
    /// Loads the next page unconditionally — no minimum-count threshold — so the row
    /// grows on demand as the user scrolls past the already-loaded cards.
    public func loadNextShortsPage() {
        let subsToken = sections.first { $0.section.type == .subscriptions }?.nextPageToken
        homeLog.notice("loadNextShortsPage: called — count=\(shortsInternalVideos.count) isLoading=\(isLoadingMoreShorts) searchToken=\(shortsNextPageToken != nil) subsToken=\(subsToken != nil)")
        guard !isLoadingMoreShorts, shortsNextPageToken != nil || subsToken != nil else {
            homeLog.notice("loadNextShortsPage: skipped — no tokens available")
            return
        }
        Task { @MainActor [weak self] in
            await self?.fetchAndAppendNextShortsPage()
        }
    }

    private func fetchAndAppendNextShortsPage() async {
        let subsToken = sections.first { $0.section.type == .subscriptions }?.nextPageToken
        guard !isLoadingMoreShorts, shortsNextPageToken != nil || subsToken != nil else { return }
        isLoadingMoreShorts = true
        defer { isLoadingMoreShorts = false }
        // Phase 1: one search page (srch: token from fetchShorts).
        if let token = shortsNextPageToken {
            homeLog.notice("loadNextShortsPage search: fetching token=\(String(token.prefix(16)))\u{2026}")
            do {
                let more = try await api.fetchShortsMore(continuationToken: token)
                let existingIDs = Set(shortsInternalVideos.map(\.id))
                let newInternalVideos = more.videos.filter { !existingIDs.contains($0.id) }
                shortsInternalVideos.append(contentsOf: newInternalVideos)
                shortsNextPageToken = more.nextPageToken
                homeLog.notice("loadNextShortsPage search: added \(newInternalVideos.count) total=\(shortsInternalVideos.count) hasMore=\(more.nextPageToken != nil)")
                if !newInternalVideos.isEmpty {
                    return // yielded new Shorts; next scroll loads the next page
                }
                // Search page returned 0 new Shorts — fall through to Phase 2
            } catch {
                homeLog.error("loadNextShortsPage search: failed: \(error.localizedDescription)")
                shortsNextPageToken = nil
            }
        }
        // Phase 2: one subs page when search is exhausted.
        // Loading one page per call lets user-triggered scrolls append more pages lazily.
        if let idx = sections.firstIndex(where: { $0.section.type == .subscriptions }),
           let token = sections[idx].nextPageToken {
            homeLog.notice("loadNextShortsPage subs: fetching token=\(String(token.prefix(16)))\u{2026}")
            do {
                let more = try await Self.fetchMoreInternalVideos(type: .subscriptions, token: token, api: api)
                let existingIDs = Set(sections[idx].videos.map(\.id))
                let newInternalVideos = more.0.filter { !existingIDs.contains($0.id) }
                sections[idx].videos.append(contentsOf: newInternalVideos)
                sections[idx].nextPageToken = more.1
                let newShorts = newInternalVideos.filter { $0.isShort }.count
                homeLog.notice("loadNextShortsPage subs: added \(newInternalVideos.count) (\(newShorts) shorts) hasMore=\(more.1 != nil)")
            } catch {
                homeLog.error("loadNextShortsPage subs: failed: \(error.localizedDescription)")
            }
        }
    }

    /// Auto-loads an additional page of FEshorts if the current count falls below
    /// the threshold needed to fill 2 horizontal screens.
    /// iOS: ~3 cards/screen → threshold = 6; tvOS: ~4 cards/screen → threshold = 8.
    func loadMoreShortsIfNeeded() async {
        #if os(tvOS)
        let threshold = 8
        #else
        let threshold = 6
        #endif
        guard !isLoadingMoreShorts else {
            homeLog.notice("loadMoreShortsIfNeeded: skipped — already loading")
            return
        }
        guard shortsInternalVideos.count < threshold, shortsNextPageToken != nil else {
            // If search token is exhausted but subs has a continuation, Phase 2 of
            // loadNextShortsPage will cover it. Nothing to do here.
            homeLog.notice("loadMoreShortsIfNeeded: skipped count=\(shortsInternalVideos.count) hasToken=\(shortsNextPageToken != nil) loading=\(isLoadingMoreShorts)")
            return
        }
        isLoadingMoreShorts = true
        defer { isLoadingMoreShorts = false }
        var loopIteration = 0
        // Loop until we have at least `threshold` items or pages run out.
        while shortsInternalVideos.count < threshold, let token = shortsNextPageToken {
            loopIteration += 1
            homeLog.notice("loadMoreShortsIfNeeded: loop=\(loopIteration) count=\(shortsInternalVideos.count) threshold=\(threshold) token=\(token.prefix(16))…")
            do {
                let more = try await api.fetchShortsMore(continuationToken: token)
                let existingIDs = Set(shortsInternalVideos.map(\.id))
                let newInternalVideos = more.videos.filter { !existingIDs.contains($0.id) }
                shortsInternalVideos.append(contentsOf: newInternalVideos)
                shortsNextPageToken = more.nextPageToken
                homeLog.notice("loadMoreShortsIfNeeded: added \(newInternalVideos.count) total=\(shortsInternalVideos.count)")
                if newInternalVideos.isEmpty {
                    // No new content on this page — avoid an infinite loop.
                    break
                }
            } catch {
                homeLog.error("loadMoreShortsIfNeeded: fetch failed: \(error.localizedDescription)")
                break
            }
        }
    }

    // MARK: - Private fetch helpers

    /// Fetches the FEshorts feed. Non-isolated so it runs concurrently with
    /// the home/subs task group.
    private static func fetchShortsInternalVideos(api: any InnerTubeAPIProtocol) async -> ([InternalVideo], String?) {
        do {
            let group = try await api.fetchShorts()
            let hasToken = group.nextPageToken != nil
            homeLog.notice("fetchShortsInternalVideos → \(group.videos.count) shorts hasToken=\(hasToken)")
            return (group.videos, group.nextPageToken)
        } catch {
            homeLog.error("fetchShortsInternalVideos failed: \(error.localizedDescription)")
            return ([], nil)
        }
    }

    /// Non-isolated so child tasks run on the global executor and network
    /// calls can overlap.
    private static func fetchInternalVideos(type: BrowseSection.SectionType, api: any InnerTubeAPIProtocol) async -> ([InternalVideo], String?) {
        do {
            switch type {
            case .subscriptions:
                let group = try await api.fetchSubscriptions()
                let shortsCount = group.videos.filter { $0.isShort }.count
                homeLog.notice("fetchInternalVideos subs: total=\(group.videos.count) shorts=\(shortsCount) regular=\(group.videos.count - shortsCount)")
                return (Array(group.videos.prefix(InnerTubeClients.maxInternalVideoResults)), group.nextPageToken)
            case .home:
                let rows = try await api.fetchHomeRows()
                let token = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                var seen = Set<String>()
                let deduped = rows.flatMap(\.videos).filter { seen.insert($0.id).inserted }
                let fetchedShortsCount = deduped.filter { $0.isShort }.count
                homeLog.notice("fetchInternalVideos home: total=\(deduped.count) shorts=\(fetchedShortsCount) regular=\(deduped.count - fetchedShortsCount)")
                if deduped.isEmpty {
                    // Home feed empty (no watch history / feedNudgeRenderer) — fall back to popular
                    let popular = try await api.search(query: "popular")
                    return (popular.videos, popular.nextPageToken)
                }
                return (Array(deduped.prefix(InnerTubeClients.maxInternalVideoResults)), token)
            default:
                return ([], nil)
            }
        } catch {
            homeLog.error("HomeViewModel fetch \(String(describing: type)): \(error.localizedDescription)")
            return ([], nil)
        }
    }

    private static func fetchMoreInternalVideos(type: BrowseSection.SectionType, token: String, api: any InnerTubeAPIProtocol) async -> ([InternalVideo], String?) {
        do {
            switch type {
            case .subscriptions:
                let group = try await retryWithBackoff(label: "HomeVM.subs") {
                    try await api.fetchSubscriptions(continuationToken: token)
                }
                let shortsCount = group.videos.filter { $0.isShort }.count
                homeLog.notice("fetchMoreInternalVideos subs: total=\(group.videos.count) shorts=\(shortsCount) regular=\(group.videos.count - shortsCount)")
                return (group.videos, group.nextPageToken)
            case .home:
                let rows = try await retryWithBackoff(label: "HomeVM.home") {
                    try await api.fetchHomeRows(continuationToken: token)
                }
                let nextToken = rows.last(where: { $0.nextPageToken != nil })?.nextPageToken
                // Dedup within the page — YouTube can return the same video ID
                // in multiple shelves of the same continuation response.
                var seen = Set<String>()
                let deduped = rows.flatMap(\.videos).filter { seen.insert($0.id).inserted }
                return (deduped, nextToken)
            default:
                return ([], nil)
            }
        } catch {
            homeLog.error("HomeViewModel loadMore \(String(describing: type)): \(error.localizedDescription)")
            return ([], nil)
        }
    }
}

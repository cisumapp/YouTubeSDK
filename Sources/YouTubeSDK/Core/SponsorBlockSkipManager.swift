#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation
#if canImport(Observation)
import Observation
#endif

// MARK: - SponsorBlockDelegate

/// Implemented by PlaybackViewModel to give SponsorBlockSkipManager the minimal
/// cross-boundary surface it needs without taking a direct reference to the full VM.
@MainActor
public protocol SponsorBlockDelegate: AnyObject {
    var settings: AppSettings { get }
    var duration: Double { get }
    func seek(to seconds: Double)
    func handlePlaybackEnd()
    func showControls()
    /// Snaps the observable `currentTime` to `seconds` after a seek completes,
    /// so the UI does not flash the pre-seek position while AVPlayer settles.
    func snapCurrentTime(to seconds: Double)
}

// MARK: - SponsorBlockSkipManager

/// Owns `sponsorSegments`, `currentToastSegment`, and `isSkippingSegment`.
/// Called from the PlaybackViewModel time observer; all logic migrated from
/// PlaybackViewModel+SponsorBlock.swift.
@MainActor
#if canImport(Observation)
@Observable
#endif
public final class SponsorBlockSkipManager {
    // MARK: - State

    public var sponsorSegments: [SponsorSegment] = []
    public var currentToastSegment: SponsorSegment?
    /// True while a SponsorBlock auto-skip seek is in-flight. Guards against the
    /// periodic time observer re-triggering before the seek completes.
    public private(set) var isSkippingSegment: Bool = false

    // MARK: - Dependencies

#if canImport(Observation)
    @ObservationIgnored public weak var delegate: (any SponsorBlockDelegate)?
#else
    public weak var delegate: (any SponsorBlockDelegate)?
#endif

#if canImport(AVFoundation)
#if canImport(Observation)
    @ObservationIgnored public var player: AVPlayer?
#else
    public var player: AVPlayer?
#endif
#endif

    // MARK: - Init

    public init() {}

    // MARK: - Interface

    public func reset() {
        sponsorSegments = []
        currentToastSegment = nil
        isSkippingSegment = false
    }

    /// Called from the time observer. Handles per-category actions:
    ///   `.skip`      → seeks past the segment automatically.
    ///   `.showToast` → surfaces `currentToastSegment` for the skip button.
    ///   `.nothing`   → no-op.
    /// Returns true if an auto-seek was triggered.
    @discardableResult
    public func checkSponsorSkip(at time: TimeInterval) -> Bool {
        guard let delegate, delegate.settings.sponsorBlockEnabled else {
            currentToastSegment = nil
            return false
        }
        if let seg = sponsorSegments.first(where: { time >= $0.start && time < $0.end }) {
            switch delegate.settings.sponsorAction(for: seg.category) {
            case .skip:
                guard !isSkippingSegment else { return true }
                currentToastSegment = nil
#if canImport(AVFoundation)
                let effectiveDuration = player?.currentItem?.duration.seconds ?? delegate.duration
#else
                let effectiveDuration = delegate.duration
#endif
                if effectiveDuration > 0, seg.end >= effectiveDuration - 2.0 {
                    delegate.handlePlaybackEnd()
                    return true
                }
                isSkippingSegment = true
#if canImport(AVFoundation)
                guard let player else { return true }
                player.seek(
                    to: CMTime(seconds: seg.end, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
                ) { [weak self] finished in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if finished { self.delegate?.snapCurrentTime(to: seg.end) }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        isSkippingSegment = false
                    }
                }
#else
                delegate.snapCurrentTime(to: seg.end)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    isSkippingSegment = false
                }
#endif
                return true
            case .showToast:
                currentToastSegment = seg
                return false
            case .nothing:
                currentToastSegment = nil
                return false
            }
        } else {
            currentToastSegment = nil
        }
        return false
    }

    /// Manually skip the segment shown in `currentToastSegment` (called by skip button).
    public func skipToastSegment() {
        guard let seg = currentToastSegment else { return }
        currentToastSegment = nil
#if canImport(AVFoundation)
        let effectiveDuration = player?.currentItem?.duration.seconds ?? delegate?.duration ?? 0
#else
        let effectiveDuration = delegate?.duration ?? 0
#endif
        if effectiveDuration > 0, seg.end >= effectiveDuration - 2.0 {
            delegate?.handlePlaybackEnd()
            return
        }
        delegate?.seek(to: seg.end)
        delegate?.showControls()
    }
}

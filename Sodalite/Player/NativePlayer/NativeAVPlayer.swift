import Foundation
import AVFoundation
import Combine

/// `AVPlayer` + `AVPlayerLayer` wrapper used by the Sodalite player
/// when `PlayerViewModel`'s routing decides a session should go
/// through the native AVKit pipeline. The only reason this path
/// exists at all: tvOS does not expose the HDMI HDR-mode handshake
/// to "Dolby Vision" through `AVSampleBufferDisplayLayer`, only
/// through `AVPlayer`-rooted playback. AetherEngine produces a
/// loopback HLS-fMP4 URL via `startNativeVideoSession(url:)` and
/// this class drives the AVKit side that consumes it.
///
/// Display-criteria handling lives in `PlayerViewModel.applyDisplay
/// Criteria(format:)` (the existing tvOS 17+ path that builds an
/// `AVDisplayCriteria(refreshRate:formatDescription:)` from a
/// HEVC+BT.2020+PQ format description). The host calls that before
/// `load(url:)`, so by the time AVPlayer's first segment fetch
/// reaches the system the HDMI HDR-mode handshake is already in
/// flight.
@MainActor
final class NativeAVPlayer: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isReady: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var failureMessage: String?

    // MARK: - Output

    /// The video layer the host mounts in `PlayerView`. Created at
    /// init time and reused for the lifetime of this wrapper, even
    /// across `replaceCurrentItem` swaps.
    let playerLayer: AVPlayerLayer

    /// The underlying `AVPlayer`. Exposed so callers can do things
    /// the published state doesn't cover (`AVMediaSelection` for
    /// audio / subtitle track switching in phase 6).
    let avPlayer: AVPlayer

    // MARK: - Private state

    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?

    // MARK: - Init

    init() {
        let player = AVPlayer()
        // Default (true) is right for VOD HLS, AVPlayer waits for
        // buffer. HLSAudioEngine sets `false` for live-audio latency
        // reasons, don't copy that pattern here: AVPlayer would try
        // to play the moment seg0 has any bytes and stall because
        // the lazy remuxer needs seconds to produce a full fragment.
        self.avPlayer = player
        self.playerLayer = AVPlayerLayer(player: player)
        self.playerLayer.videoGravity = .resizeAspect
    }

    // No deinit cleanup: under Swift 6 strict concurrency the deinit
    // of a `@MainActor` type is nonisolated and can't reach
    // main-isolated properties. Callers must call `tearDown()`
    // before dropping the wrapper. PlayerViewModel.stopPlayback
    // already does this; PlayerView.viewWillDisappear funnels into
    // the same path.

    // MARK: - Lifecycle

    /// Load the URL produced by `AetherEngine.startNativeVideoSession`.
    /// The display-criteria handshake is the host's responsibility
    /// (call `PlayerViewModel.applyDisplayCriteria` before this) so
    /// AVKit can configure the HDR pipeline against the right target
    /// mode before the first segment is fetched.
    func load(url: URL, startPosition: Double?) {
        unloadCurrentItem()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        playerItem = item
        failureMessage = nil
        isReady = false

        // Status observer to track readyToPlay / failed transitions.
        // KVO observation runs on the same thread that mutated the
        // observed value, in this case AVPlayerItem hops to its own
        // queue, so we round-trip back to MainActor explicitly.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self = self else { return }
                switch item.status {
                case .readyToPlay:
                    self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
                    self.isReady = true
                case .failed:
                    self.failureMessage = item.error?.localizedDescription ?? "AVPlayerItem failed (no description)"
                default:
                    break
                }
            }
        }

        rateObservation = avPlayer.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.rate = player.rate
            }
        }

        // Periodic time observer at 100 ms drives the scrub bar
        // and the resume-position progress reporter. The closure is
        // already invoked on `.main`, so the `MainActor` mutation
        // is safe; cast through a Task to satisfy the Sendable check.
        timeObserver = avPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let value = time.seconds.isFinite ? time.seconds : 0
            Task { @MainActor in
                self?.currentTime = value
            }
        }

        avPlayer.replaceCurrentItem(with: item)

        if let start = startPosition, start > 0 {
            seek(to: start)
        }
    }

    /// Release the AVPlayerItem so a follow-up `load(...)` starts
    /// from a clean state. Does not touch the host window's
    /// display-criteria; that's reset by the host alongside its
    /// existing `resetDisplayCriteria()` flow.
    func tearDown() {
        unloadCurrentItem()
    }

    // MARK: - Playback control

    func play() {
        avPlayer.play()
    }

    func pause() {
        avPlayer.pause()
    }

    /// Toggle between play and pause based on the current
    /// `timeControlStatus`. The KVO-observed `rate` is also valid
    /// here but reads as 0 during a buffer stall (which we don't
    /// want to interpret as "paused"); `timeControlStatus`
    /// distinguishes those.
    func toggle() {
        switch avPlayer.timeControlStatus {
        case .playing:
            pause()
        default:
            play()
        }
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ value: Float) {
        avPlayer.rate = value
    }

    // MARK: - Internal

    private func unloadCurrentItem() {
        if let to = timeObserver {
            avPlayer.removeTimeObserver(to)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil
        avPlayer.replaceCurrentItem(with: nil)
        playerItem = nil
        isReady = false
        currentTime = 0
        duration = 0
        rate = 0
    }
}

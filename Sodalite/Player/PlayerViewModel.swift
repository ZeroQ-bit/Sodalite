import Foundation
import Combine
import Observation
import AetherEngine
import AVKit
import os

/// ViewModel that bridges AetherEngine with Jellyfin session reporting
/// and our custom tvOS-style player UI.
///
/// Uses Combine subscriptions to observe AetherEngine's @Published
/// properties instead of polling timers, eliminates AttributeGraph cycles.
///
/// Split into extensions:
/// - `PlayerViewModel+Scrubbing.swift`, pan/arrow scrubbing
/// - `PlayerViewModel+NextEpisode.swift`, auto-play next episode
/// - `PlayerViewModel+SessionReporting.swift`, Jellyfin progress reports
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - UI State

    var isLoading = true
    var errorMessage: String?
    /// Icon (SF Symbol) chosen for the active error, set together
    /// with `errorMessage` via `setError(from:)`. nil when no error.
    var errorIcon: String?
    /// Localised headline for the active error (e.g. "Connection
    /// problem" / "Sign-in required"). Sits above `errorMessage` in
    /// the player overlay; the message provides the detail.
    var errorTitle: String?
    var isPlaying = false
    var showControls = false

    // Time display
    var currentTime: String = "00:00"
    var totalTime: String = "00:00"
    var remainingTime: String = "-00:00"
    var progress: Float = 0

    // Playback time (raw seconds, tracked by @Observable for subtitle sync)
    var playbackTime: Double = 0

    // Scrubbing
    var isScrubbing = false
    var scrubProgress: Float = 0
    var scrubTime: String = "00:00"
    var displayedProgress: Float { isScrubbing ? scrubProgress : progress }
    var scrubStartProgress: Float = 0

    // Custom focus for transport bar navigation
    var controlsFocus: ControlsFocus = .progressBar
    var trackDropdown: TrackDropdown = .none

    enum ControlsFocus: Hashable {
        case progressBar
        case skipIntroButton
        case chapterButton
        case episodeButton
        case audioButton
        case subtitleButton
        case speedButton
        case pictureButton
    }

    enum TrackDropdown: Equatable {
        case none
        case chapter(highlighted: Int)  // index into chapters
        case episode(highlighted: Int)  // index into seasonEpisodes
        case audio(highlighted: Int)   // index into player.audioTracks
        case subtitle(highlighted: Int) // index into subtitle items (0=Off, 1..=tracks)
        case speed(highlighted: Int)    // index into PlayerViewModel.speedOptions
        case picture(highlighted: Int)  // index into PlaybackPreferences.PictureMode.allCases
    }

    var isDropdownOpen: Bool { trackDropdown != .none }

    /// Playback speed choices. Native tvOS player uses the same stepped
    /// set, keeping it consistent with user expectations. Index 2 = 1.0×.
    static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    /// Index into `speedOptions` for the currently applied rate.
    var activeSpeedIndex: Int = 2

    // Tracks
    var subtitleCues: [SubtitleCue] = []
    var activeAudioIndex: Int?
    var activeSubtitleIndex: Int?

    /// Episodes from the currently-playing item's season, sorted by
    /// indexNumber. Populated lazily after startPlayback so the
    /// transport bar can offer an in-season episode picker without
    /// the user having to back out to the series detail screen.
    /// Stays empty for movies, single-episode series, and any item
    /// without a parent season, TransportBar suppresses the button
    /// when count <= 1.
    var seasonEpisodes: [JellyfinItem] = []

    /// Chapter markers from the source container. Populated at
    /// startPlayback from `item.chapters`. Sorted by start position
    /// so the scrub-bar overlay can iterate without re-sorting and
    /// the chapter dropdown lists them in playback order. Empty when
    /// the file ships no chapters, TransportBar suppresses the
    /// button when count <= 1.
    var chapters: [ChapterInfo] = []

    /// Picture-fill mode for the currently active session. Initialised
    /// at `startPlayback` from the user's `PlaybackPreferences.pictureMode`,
    /// then mutable on the fly via `selectPictureMode`. Doesn't write
    /// back to prefs, the in-player picker is treated as a transient
    /// override for this playback only, the settings screen owns the
    /// global default.
    var pictureMode: PlaybackPreferences.PictureMode = .original

    // Video format (HDR/DV indicator)
    var videoFormat: VideoFormat = .sdr

    // Next episode
    var nextEpisode: JellyfinItem?
    var showNextEpisodeOverlay = false
    var nextEpisodeCountdown = 10
    /// Fired once when playback hits demux EOF and there's no next
    /// episode to advance to (movies, last episode of a season /
    /// series). PlayerView wires this up to the same dismiss path the
    /// Menu button takes, without it, the player sits on a black
    /// frame with no focus target and the user has to mash Menu to
    /// get back to the detail screen they came from.
    var onPlaybackReachedEnd: (() -> Void)?
    var isCountdownActive = false
    var nextEpisodeTimer: Task<Void, Never>?
    var hasFetchedNextEpisode = false
    var nextEpisodeCancelled = false

    // Intro skip + outro-aware next-episode trigger, both populated
    // from Jellyfin Media Segments / intro-skipper plugin in one call.
    var introSegment: MediaSegment?
    var outroSegment: MediaSegment?
    /// True while playbackTime is inside the intro range. UI shows the
    /// Skip Intro button whenever this is true, regardless of whether
    /// the transport controls are open.
    var isInsideIntro: Bool = false
    /// Set once per episode after an auto-skip fires, keeps the time
    /// subscriber from re-triggering the skip in the brief window before
    /// the seek actually moves currentTime past introEnd.
    var didAutoSkipCurrentIntro: Bool = false
    /// Mirrors `didAutoSkipCurrentIntro` for the outro segment. Set the
    /// first tick after playback crosses into the outro range; prevents
    /// the auto-skip from firing repeatedly while currentTime ticks
    /// through the couple of seconds between the marker and the seek
    /// landing on outro.endSeconds.
    var didAutoSkipCurrentOutro: Bool = false

    // MARK: - Dependencies

    var item: JellyfinItem
    let player: AetherEngine

    let playbackService: JellyfinPlaybackServiceProtocol
    let userID: String
    var startFromBeginning: Bool
    var cachedPlaybackInfo: PlaybackInfoResponse?
    let preferences: PlaybackPreferences

    // MARK: - Internal State

    var cancellables = Set<AnyCancellable>()
    var progressTimer: Task<Void, Never>?
    var controlsTimer: Task<Void, Never>?
    var hasReportedStart = false
    var hasStartedPlaying = false
    /// The position we resumed from, used as minimum for progress reports
    /// to prevent Jellyfin from resetting progress when stopping early.
    var resumePositionTicks: Int64 = 0
    var mediaSourceID: String = ""
    var playSessionID: String?
    var activePlayMethod: PlayMethod = .directPlay
    var subtitleStreams: [MediaStream] = []

    init(
        item: JellyfinItem,
        startFromBeginning: Bool,
        playbackService: JellyfinPlaybackServiceProtocol,
        userID: String,
        preferences: PlaybackPreferences,
        cachedPlaybackInfo: PlaybackInfoResponse? = nil
    ) {
        self.item = item
        self.player = DependencyContainer.playerEngine
        self.startFromBeginning = startFromBeginning
        self.playbackService = playbackService
        self.userID = userID
        self.preferences = preferences
        self.cachedPlaybackInfo = cachedPlaybackInfo
    }

    // MARK: - Lifecycle

    func startPlayback() async {
        isLoading = true
        clearError()
        // Source-container chapters are already on the item if the
        // detail fetch requested the Chapters field. Sort defensively
        //, the API documents start-position order but a few legacy
        // taggers emit them out of sequence.
        chapters = (item.chapters ?? [])
            .sorted { $0.startPositionTicks < $1.startPositionTicks }
        // Reset the picture mode to the user's global default for
        // each new playback session, in-player overrides shouldn't
        // bleed across episodes / movies.
        pictureMode = preferences.pictureMode
        applyPictureMode()
        #if DEBUG
        print("[PlayerVM] startPlayback: item=\(item.name), seriesId=\(item.seriesId ?? "nil"), type=\(item.type), chapters=\(chapters.count)")
        #endif

        do {
            let info: PlaybackInfoResponse
            if let cached = cachedPlaybackInfo, !cached.mediaSources.isEmpty {
                info = cached
            } else {
                info = try await playbackService.getPlaybackInfo(
                    itemID: item.id,
                    userID: userID,
                    profile: DirectPlayProfile.current()
                )
            }
            playSessionID = info.playSessionId

            guard let source = info.mediaSources.first else {
                throw PlayerEngineError.noSource
            }
            mediaSourceID = source.id

            #if DEBUG
            print("[PlayerViewModel] Source: container=\(source.container ?? "nil"), directPlay=\(source.supportsDirectPlay ?? false), directStream=\(source.supportsDirectStream ?? false), transcoding=\(source.supportsTranscoding ?? false)")
            if let tURL = source.transcodingUrl {
                print("[PlayerViewModel] TranscodingURL: \(tURL.prefix(120))...")
            }
            #endif

            // Filter subtitle streams:
            // 1. Exclude image-based formats (PGS, VOBSUB), can't convert to text
            // 2. Drop forced tracks, they only cover foreign-dialogue
            //    segments inside an otherwise-understood audio track, so
            //    users rarely want them on; keeping them also poisons the
            //    preferred-language auto-select (a forced "deu" beats a
            //    full "deu" track if it comes first).
            // 3. Deduplicate same-language streams with no distinguishing metadata.
            // Bitmap codecs (PGS / HDMV / DVB / DVD) used to be excluded
            // here because the legacy server-extraction path couldn't
            // produce SRT for them. The engine renders them as CGImage
            // now, so they belong in the picker. "Forced" tracks also
            // stay in the list, many releases mark every subtitle
            // track as forced and we'd otherwise leave the user with
            // an empty dropdown for a file that obviously has subs.
            // The dedupe step below uses `forced` / `signs` / `sdh` /
            // etc. as descriptors so distinct tracks for the same
            // language don't collapse into one.
            let allSubStreams = source.mediaStreams?.filter { stream in
                stream.type == .subtitle
            } ?? []

            // Deduplicate: if multiple streams share the same language and
            // neither has a distinguishing title (SDH, Forced, etc.),
            // keep only the first one. Streams with descriptors keep
            // each variant under its own key so e.g. "Forced (SRT)"
            // and "Full (PGS)" both survive even when they share a
            // language tag.
            var seen = Set<String>()
            subtitleStreams = allSubStreams.filter { stream in
                let lang = stream.language ?? "und"
                let hasDescriptor = stream.isForced == true
                    || (stream.title?.lowercased()).map { t in
                        ["sdh", "commentary", "cc", "signs", "songs", "hearing", "forced", "musik", "music", "full"].contains(where: { t.contains($0) })
                    } ?? false
                let codecKey = stream.codec?.lowercased() ?? ""
                let key = hasDescriptor
                    ? "\(lang)_\(stream.title ?? "")_\(codecKey)"
                    : "\(lang)_\(codecKey)"
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }

            let url: URL
            if source.supportsDirectPlay == true || source.supportsDirectStream == true {
                let isDirectPlay = source.supportsDirectPlay == true
                guard let directURL = playbackService.buildStreamURL(
                    itemID: item.id,
                    mediaSourceID: source.id,
                    container: source.container,
                    isStatic: isDirectPlay
                ) else {
                    throw PlayerEngineError.noURL
                }
                url = directURL
                activePlayMethod = isDirectPlay ? .directPlay : .directStream
                #if DEBUG
                print("[PlayerViewModel] Using direct \(isDirectPlay ? "play" : "stream")")
                #endif
            } else if let transcodePath = source.transcodingUrl, !transcodePath.isEmpty {
                guard let transcodeURL = playbackService.buildTranscodeURL(relativePath: transcodePath) else {
                    throw PlayerEngineError.noURL
                }
                url = transcodeURL
                activePlayMethod = .transcode
                #if DEBUG
                print("[PlayerViewModel] Using transcoded stream")
                #endif
            } else {
                throw PlayerEngineError.noURL
            }

            let startPos: Double?
            if !startFromBeginning,
               let ticks = item.userData?.playbackPositionTicks, ticks > 0 {
                startPos = ticks.ticksToSeconds
                resumePositionTicks = ticks
            } else {
                startPos = nil
                resumePositionTicks = 0
            }

            // Set display criteria BEFORE loading, the TV needs time to switch
            // to HDR/DV mode before the first frame is decoded. Use Jellyfin's
            // mediaStreams metadata for detection (available before decode).
            //
            // If the display won't actually switch (Match Content disabled,
            // SDR panel, no window), we must tone-map HDR→SDR during decode.
            // Without tone-mapping, AVSampleBufferDisplayLayer shows black
            // because it can't map PQ values onto an SDR display.
            let detectedFormat = detectVideoFormat(from: source)
            var displayWillSwitchToHDR = false
            if detectedFormat != .sdr {
                // If content is DV but TV only supports HDR10, use HDR10 criteria
                let displayFormat: VideoFormat
                if detectedFormat == .dolbyVision && !DisplayCapabilities.supportsDolbyVision {
                    displayFormat = .hdr10
                } else {
                    displayFormat = detectedFormat
                }
                displayWillSwitchToHDR = applyDisplayCriteria(format: displayFormat)
                if displayWillSwitchToHDR {
                    // waitForDisplayModeSwitch() polls
                    // isDisplayModeSwitchInProgress every 100 ms and
                    // returns immediately when the flag is false. So
                    // if the TV is already in the target HDR mode (e.g.
                    // user just watched another HDR film) it costs us
                    // a single check, not the full pre-sleep + wait
                    // dance. The previous unconditional 200 ms sleep
                    // was paid even in that no-op case.
                    await waitForDisplayModeSwitch()
                }
            }

            // Tone-map when source is HDR but display stays in SDR.
            let tonemapHDRToSDR = detectedFormat != .sdr && !displayWillSwitchToHDR
            #if DEBUG
            if tonemapHDRToSDR {
                print("[PlayerVM] Tone-mapping HDR→SDR (display stays in SDR mode)")
            }
            #endif

            try await player.load(
                url: url,
                startPosition: startPos,
                tonemapHDRToSDR: tonemapHDRToSDR
            )

            totalTime = formatSeconds(effectiveDuration)
            // Audio track priority: preferred language → stream default → first.
            let preferredAudio = effectivePreferredAudioLanguage()
            let chosenAudio = player.audioTracks.first(where: {
                preferredAudio != nil && Self.languagesMatch($0.language, preferredAudio)
            }) ?? player.audioTracks.first(where: { $0.isDefault })
              ?? player.audioTracks.first
            if let chosenAudio {
                activeAudioIndex = chosenAudio.id
                player.selectAudioTrack(index: chosenAudio.id)
            }

            applyPreferredSubtitle(forAudioLanguage: chosenAudio?.language)

            isLoading = false
            isPlaying = true

            startObserving()
            await reportStart()
            startProgressReporting()

            // Fetch intro marker in the background, don't block
            // playback start if the server is slow or doesn't expose
            // the endpoint. Once the marker lands the next time tick
            // will flip isInsideIntro on naturally.
            Task { [weak self] in await self?.loadEpisodeSegments() }

            // Same fire-and-forget: the season episode list powers the
            // transport-bar episode picker. A movie or single-episode
            // series leaves the list empty and the picker stays hidden.
            Task { [weak self] in await self?.loadSeasonEpisodes() }

        } catch {
            setError(from: error)
            isLoading = false
        }
    }

    func stopPlayback() async {
        stopProgressReporting()
        cancellables.removeAll()
        // Capture position synchronously, then stop the engine, then
        // report. The capture-then-stop order is critical: player.stop()
        // resets currentTime to 0, so we'd lose the position if we read
        // it inside reportStop after the stop. By passing the captured
        // ticks explicitly we keep the proven progress-sync correctness
        // of the old "report before stop" flow, while killing the
        // ~1-2s of trailing audio that the user heard during the
        // network round-trip.
        let finalTicks = currentPositionTicks
        player.stop()
        // Always revert the TV to SDR once playback ends. PlayerView's
        // onDisappear also calls this, but if the app is backgrounded or
        // the VC is torn down by other means, we still want the TV back in
        // SDR mode so menus don't stay in HDR.
        resetDisplayCriteria()
        await reportStop(positionTicks: finalTicks)
    }

    // MARK: - State Observation (Combine)

    private func startObserving() {
        player.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing:
                    self.hasStartedPlaying = true
                    self.isLoading = false
                    self.isPlaying = true
                    if self.showControls { self.scheduleControlsHide() }
                case .paused:
                    self.isLoading = false
                    self.isPlaying = false
                case .idle:
                    self.isPlaying = false
                    // Demux EOF, safety net countdown start for cases
                    // where player.$currentTime never fires near the
                    // end (Combine only emits on value changes, and
                    // the demux's 15–20 s look-ahead means currentTime
                    // can stall a few seconds short of duration). Cap
                    // at 10 s so the overlay copy stays readable even
                    // if the real remaining is tiny.
                    if self.hasStartedPlaying,
                       self.nextEpisode != nil,
                       !self.nextEpisodeCancelled,
                       self.nextEpisodeTimer == nil {
                        let remaining = self.effectiveDuration - self.playbackTime
                        let seconds = min(10, max(1, Int(ceil(max(0, remaining)))))
                        self.showNextEpisodeOverlay = true
                        self.startNextEpisodeCountdown(from: seconds)
                    } else if self.hasStartedPlaying,
                              self.nextEpisode == nil,
                              !self.showNextEpisodeOverlay {
                        // Real end-of-content: a movie just finished, or
                        // the last episode of a series rolled credits.
                        // Without this the player sits on a black frame
                        // with no focus target, Menu still works to
                        // exit, but the natural flow is to drop the user
                        // back on the detail view they came from.
                        self.onPlaybackReachedEnd?()
                    }
                case .loading:
                    if !self.hasStartedPlaying { self.isLoading = true }
                case .seeking:
                    break
                case .error(let msg):
                    self.setEnginePlaybackError(message: msg)
                    self.isLoading = false
                }
            }
            .store(in: &cancellables)

        player.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.playbackTime = time
                self.updateIntroVisibility(time: time)
                self.updateOutroAutoSkip(time: time)
                self.checkForNextEpisode()
                let dur = self.effectiveDuration
                let remaining = dur - time
                if self.nextEpisode != nil && !self.nextEpisodeCancelled && dur > 0 && remaining > 0 {
                    // Two separate UI-visibility flows depending on
                    // whether the server gave us an outro marker.
                    //
                    // Outro available:
                    //   Credits typically run 2–3 minutes. Show the
                    //   overlay the moment we cross outro.startSeconds
                    //   and fire a fixed 10 s countdown, transition
                    //   happens well before the episode naturally ends,
                    //   cutting through the credits.
                    //
                    // No outro:
                    //   Fall back to "show at 30 s, countdown at 10 s
                    //   remaining, synced to the clock." Countdown
                    //   hits 0 right at playback end, seamless
                    //   transition that doesn't cut anything off.
                    if let outro = self.outroSegment {
                        let pastOutroStart = time >= outro.startSeconds
                        if pastOutroStart && !self.showNextEpisodeOverlay {
                            self.showNextEpisodeOverlay = true
                        }
                        if pastOutroStart, self.nextEpisodeTimer == nil, self.showNextEpisodeOverlay {
                            self.startNextEpisodeCountdown()
                        }
                    } else {
                        if !self.showNextEpisodeOverlay && remaining < 30 {
                            self.showNextEpisodeOverlay = true
                        }
                        if remaining <= 10, self.nextEpisodeTimer == nil, self.showNextEpisodeOverlay {
                            self.startNextEpisodeCountdown(from: Int(ceil(remaining)))
                        }
                    }
                }
                guard !self.isScrubbing else { return }
                self.currentTime = self.formatSeconds(time)
                let rem = dur - time
                self.remainingTime = rem > 0 ? "-\(self.formatSeconds(rem))" : "-00:00"
                self.progress = dur > 0 ? Float(time / dur) : 0
            }
            .store(in: &cancellables)

        player.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                guard let self else { return }
                self.totalTime = dur > 0 ? self.formatSeconds(dur) : "00:00"
            }
            .store(in: &cancellables)

        player.$videoFormat
            .receive(on: DispatchQueue.main)
            .sink { [weak self] format in
                guard let self else { return }
                // Only show the HDR badge if the display is actually in
                // HDR mode. When "Match Dynamic Range" is off, the TV
                // stays in SDR, showing "HDR10" would be misleading.
                #if os(tvOS)
                if format != .sdr {
                    let matchEnabled = self.displayWindow?.avDisplayManager
                        .isDisplayCriteriaMatchingEnabled ?? false
                    if !matchEnabled {
                        self.videoFormat = .sdr
                        return
                    }
                }
                #endif
                self.videoFormat = format
            }
            .store(in: &cancellables)

        // Engine subtitle pipeline, covers both embedded streams
        // (cues stream in from the main demux loop) and sidecar
        // files (cues arrive in one batch when SubtitleDecoder
        // finishes). Mirror them into our `subtitleCues` whenever
        // the engine is the source. The legacy HTTP path for
        // bitmap codecs / transcoded sessions writes `subtitleCues`
        // directly with `isSubtitleActive == false`, so the guard
        // keeps those two paths from clobbering each other.
        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                guard self.player.isSubtitleActive else { return }
                self.subtitleCues = cues
            }
            .store(in: &cancellables)
    }

    // MARK: - Controls

    func togglePlayPause() {
        player.togglePlayPause()
        reportProgressIfNeeded()
        showControls = true
        scheduleControlsHide()
    }

    /// Seek by the user's configured interval (5/10/15/30 s). The
    /// direction is +1 (right) or −1 (left). Wraps the seconds variant
    /// so the press handler doesn't need a Preferences lookup.
    func seekJumpByConfiguredInterval(direction: Int) {
        let interval = preferences.skipIntervalSeconds
        let signed = (direction < 0 ? -1 : 1) * interval
        seekJump(seconds: Double(signed))
    }

    func seekJump(seconds: Double) {
        let dur = effectiveDuration
        guard dur > 0 else { return }

        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            scrubProgress = progress
        }

        showControls = true
        controlsTimer?.cancel()

        let jumpProgress = Float(seconds / dur)
        scrubProgress = max(0, min(1, scrubProgress + jumpProgress))
        scrubTime = formatSeconds(Double(scrubProgress) * dur)

        // Auto-cancel on idle, matching `scrubPanEnded`. Commit stays
        // explicit (Select), but if the user taps left / right and
        // walks away without pressing anything else the scrub is
        // discarded after 5 s and the controls fade out, instead of
        // sitting on the picture forever.
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isScrubbing = false
            hideControls()
        }
    }

    /// Reset the error trio so a fresh `startPlayback` shows nothing
    /// stale while it loads.
    func clearError() {
        errorMessage = nil
        errorIcon = nil
        errorTitle = nil
    }

    /// Categorise an error from the playback-start path into an
    /// icon + title + body trio for the player overlay. The body
    /// stays the underlying `localizedDescription` (already localised
    /// for `APIError`) so the user sees the real reason; the icon
    /// and title give it shape.
    func setError(from error: Error) {
        let icon: String
        let title: String
        if let api = error as? APIError {
            switch api {
            case .serverUnreachable:
                icon = "wifi.exclamationmark"
                title = String(localized: "player.error.connection.title", defaultValue: "Connection problem")
            case .networkError:
                icon = "wifi.exclamationmark"
                title = String(localized: "player.error.connection.title", defaultValue: "Connection problem")
            case .timeout:
                icon = "clock.badge.exclamationmark"
                title = String(localized: "player.error.timeout.title", defaultValue: "Request timed out")
            case .unauthorized:
                icon = "lock.shield"
                title = String(localized: "player.error.unauthorized.title", defaultValue: "Sign-in required")
            case .httpError(let statusCode, _):
                if statusCode == 404 {
                    icon = "questionmark.folder"
                    title = String(localized: "player.error.notFound.title", defaultValue: "Item unavailable")
                } else if (500..<600).contains(statusCode) {
                    icon = "server.rack"
                    title = String(localized: "player.error.server.title", defaultValue: "Server error")
                } else {
                    icon = "exclamationmark.triangle"
                    title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
                }
            case .invalidURL, .invalidResponse, .decodingError:
                icon = "exclamationmark.triangle"
                title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
            }
        } else if let engine = error as? PlayerEngineError {
            switch engine {
            case .noSource, .noURL:
                icon = "questionmark.video"
                title = String(localized: "player.error.noVideo.title", defaultValue: "Couldn't open this video")
            }
        } else {
            icon = "exclamationmark.triangle"
            title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
        }
        errorIcon = icon
        errorTitle = title
        errorMessage = error.localizedDescription
    }

    /// Engine-side terminal error mid-playback (decoder failure,
    /// renderer death, network drop after we'd already handed off).
    /// Different category from start-up errors, playback was running
    /// and stopped, so the headline reads as such.
    func setEnginePlaybackError(message: String) {
        errorIcon = "exclamationmark.triangle"
        errorTitle = String(
            localized: "player.error.playback.title",
            defaultValue: "Playback stopped"
        )
        errorMessage = message
    }

    /// Apply the current `pictureMode` to the engine's display layer.
    /// Maps the host enum to AVLayerVideoGravity. Called on every
    /// `startPlayback` (re-applies on each new session) and from
    /// `selectPictureMode` (in-player picker).
    func applyPictureMode() {
        switch pictureMode {
        case .original: player.videoGravity = .resizeAspect
        case .fill:     player.videoGravity = .resizeAspectFill
        }
    }

    /// In-player picker change. Mutates the session-local `pictureMode`
    /// and pushes it to the engine. Doesn't persist, the user's
    /// global default lives in `PlaybackPreferences.pictureMode` and
    /// is set from the Settings screen.
    func selectPictureMode(_ mode: PlaybackPreferences.PictureMode) {
        pictureMode = mode
        applyPictureMode()
    }

    /// Seek directly to the start of a chapter. Index is into the
    /// already-sorted `chapters` array, out-of-range calls no-op.
    func selectChapter(at index: Int) {
        guard chapters.indices.contains(index) else { return }
        let target = chapters[index].startSeconds
        Task { await player.seek(to: target) }
    }

    func selectAudioTrack(id: Int) {
        activeAudioIndex = id
        player.selectAudioTrack(index: id)
        // Re-run the auto-subtitle resolution so a manual mid-playback
        // language switch behaves like the initial load did. Without
        // this, switching DE → EN inside the player kept subtitles off
        // even though autoSubtitleForForeignAudio would have turned on
        // German subs at load-time for the same audio choice.
        let language = player.audioTracks.first(where: { $0.id == id })?.language
        applyPreferredSubtitle(forAudioLanguage: language)
    }

    /// Resolves which subtitle track to surface, given the language of
    /// the currently selected audio track:
    ///
    /// 1. Explicit `preferredSubtitleLanguage` always wins.
    /// 2. Otherwise, if `autoSubtitleForForeignAudio` is on AND the
    ///    audio isn't in the preferred audio language, surface subs in
    ///    the preferred audio language, the "Netflix convention":
    ///    German audio missing → English audio plays → German subs on
    ///    top.
    /// 3. No match → leave the current subtitle selection alone (the
    ///    user may have picked one manually; we don't override it on
    ///    a switch back to native audio).
    private func applyPreferredSubtitle(forAudioLanguage audioLanguage: String?) {
        if let explicit = preferences.preferredSubtitleLanguage {
            if let match = subtitleStreams.first(where: { Self.languagesMatch($0.language, explicit) }) {
                selectSubtitleTrack(id: match.index)
            }
            return
        }
        guard preferences.autoSubtitleForForeignAudio,
              let preferredAudio = effectivePreferredAudioLanguage(),
              !Self.languagesMatch(audioLanguage, preferredAudio)
        else { return }
        if let match = subtitleStreams.first(where: { Self.languagesMatch($0.language, preferredAudio) }) {
            selectSubtitleTrack(id: match.index)
        }
    }

    /// Resolves the effective "preferred audio language" used for the
    /// foreign-audio detection. The Settings UI ships an "Auto" choice
    /// that stores nil, without a fallback that path leaves the
    /// foreign-audio guard unable to compare against anything, so a
    /// user who keeps the default never gets auto-subs even when their
    /// system locale clearly indicates the language they speak. We
    /// substitute the device's primary language code so "Auto" still
    /// behaves like "the language my Apple TV is set to".
    private func effectivePreferredAudioLanguage() -> String? {
        if let explicit = preferences.preferredAudioLanguage {
            return explicit
        }
        return Locale.current.language.languageCode?.identifier
    }

    /// Compares two language tags loosely so settings ("ger"), FFmpeg
    /// container metadata ("deu"), and BCP-47 ("de") all line up as
    /// the same language. Without this, the auto-subtitle path was
    /// silently failing for users whose preferred-audio code didn't
    /// match the format the muxer / Jellyfin happened to write into
    /// the stream.
    static func languagesMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased() else { return false }
        if a == b { return true }
        return languageSynonyms.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Equivalence classes spanning ISO 639-1, 639-2/T, and 639-2/B
    /// for every language Sodalite ships UI for plus the major ones
    /// users typically have library content in. Anything outside the
    /// table falls back to strict equality, which is fine when both
    /// sides are stamped from the same source.
    private static let languageSynonyms: [Set<String>] = [
        ["de", "deu", "ger"], ["en", "eng"], ["fr", "fra", "fre"],
        ["es", "spa"], ["it", "ita"], ["ja", "jpn"], ["ko", "kor"],
        ["zh", "zho", "chi"], ["pt", "por"], ["ru", "rus"],
        ["nl", "nld", "dut"], ["sv", "swe"], ["da", "dan"],
        ["no", "nor"], ["nb", "nob"], ["nn", "nno"],
        ["fi", "fin"], ["pl", "pol"], ["cs", "ces", "cze"],
        ["hu", "hun"], ["tr", "tur"], ["el", "ell", "gre"],
        ["ar", "ara"], ["he", "heb"], ["hi", "hin"], ["id", "ind"],
        ["th", "tha"], ["vi", "vie"], ["uk", "ukr"], ["ro", "ron", "rum"],
        ["sk", "slk", "slo"], ["hr", "hrv"], ["bg", "bul"],
        ["sr", "srp"], ["pt-br", "por"], ["pt-pt", "por"],
    ]

    // MARK: - Intro Skip

    /// Called from the playback-time Combine subscription. Toggles
    /// `isInsideIntro` so the UI can show/hide the Skip Intro button
    /// without each caller recomputing the range.
    func updateIntroVisibility(time: Double) {
        guard let seg = introSegment else {
            if isInsideIntro { setInsideIntro(false) }
            return
        }
        // Plugin sometimes reports introStart=0 on episodes with a
        // pre-title cold-open → button would pop up the instant the
        // episode starts, before the titles even play. Give it a tiny
        // lead-in so the button appears with the intro music.
        let inside = time >= max(seg.startSeconds, 0.5)
                  && time < seg.endSeconds - 1   // hide 1s before end

        // Auto-skip path: the very first tick inside the intro fires
        // the skip automatically if the user opted in. Guarded so the
        // skip only happens once per episode even as further ticks
        // arrive before currentTime has actually moved past introEnd.
        if inside && preferences.autoSkipIntro && !didAutoSkipCurrentIntro {
            didAutoSkipCurrentIntro = true
            skipIntro()
            return
        }

        if inside != isInsideIntro {
            setInsideIntro(inside)
        }
    }

    /// Update the flag *and* move focus away from the Skip Intro button
    /// if it just disappeared, otherwise the user would be stuck on a
    /// button that's no longer in the row.
    private func setInsideIntro(_ newValue: Bool) {
        isInsideIntro = newValue
        if !newValue && controlsFocus == .skipIntroButton {
            if !player.audioTracks.isEmpty { controlsFocus = .audioButton }
            else if !subtitleStreams.isEmpty { controlsFocus = .subtitleButton }
            else { controlsFocus = .speedButton }
        }
    }

    /// Jump past the intro. Triggered by the Skip Intro button.
    func skipIntro() {
        guard let seg = introSegment else { return }
        isInsideIntro = false
        Task { await player.seek(to: seg.endSeconds) }
    }

    /// Outro equivalent to `updateIntroVisibility`, no Skip Outro UI
    /// button today, so this only has to handle the auto-skip path.
    /// Fires once per episode the moment playback crosses into the
    /// outro range.
    ///
    /// Two variants depending on which combination of preferences is
    /// active:
    ///
    /// - autoSkipOutro + autoplayNextEpisode + next episode ready →
    ///   skip straight to the next episode. Keeping the 10 s
    ///   next-episode countdown on top of a user who explicitly
    ///   asked to skip outros is a contradiction.
    /// - Anything else (e.g. next episode still fetching, or
    ///   autoplayNextEpisode off): seek to outro.endSeconds and let
    ///   the regular next-episode flow pick up from there.
    func updateOutroAutoSkip(time: Double) {
        guard let seg = outroSegment,
              preferences.autoSkipOutro,
              !didAutoSkipCurrentOutro else { return }
        guard time >= seg.startSeconds else { return }
        didAutoSkipCurrentOutro = true

        if preferences.autoplayNextEpisode, nextEpisode != nil {
            Task { @MainActor [weak self] in
                await self?.playNextEpisode()
            }
        } else {
            Task { await player.seek(to: seg.endSeconds) }
        }
    }

    /// Fetch intro + outro markers once on startup. Safe if the server
    /// doesn't expose the endpoint, service returns an empty struct
    /// and the features simply stay off (no Skip Intro button, normal
    /// 30 s fallback trigger for the next-episode overlay).
    func loadEpisodeSegments() async {
        didAutoSkipCurrentIntro = false
        didAutoSkipCurrentOutro = false
        do {
            let segments = try await playbackService.getEpisodeSegments(itemID: item.id)
            introSegment = segments.intro
            outroSegment = segments.outro
        } catch {
            #if DEBUG
            print("[MediaSegments] Fetch failed: \(error)")
            #endif
            introSegment = nil
            outroSegment = nil
        }
    }

    /// Apply the playback speed at the given index in `speedOptions`.
    func selectSpeed(index: Int) {
        let clamped = max(0, min(Self.speedOptions.count - 1, index))
        activeSpeedIndex = clamped
        player.setRate(Self.speedOptions[clamped])
    }

    func selectSubtitleTrack(id: Int?) {
        guard let id else {
            activeSubtitleIndex = nil
            subtitleCues = []
            player.clearSubtitle()
            return
        }
        activeSubtitleIndex = id
        let stream = subtitleStreams.first(where: { $0.index == id })
        let isExternal = stream?.isExternal == true

        if isExternal {
            // Sidecar file (.srt / .ass / .vtt next to the media).
            // Hand the URL to the engine, it fetches the file once
            // and decodes it via FFmpeg, no host-side SRTParser. The
            // resulting cues land on `engine.subtitleCues` and the
            // mirror sink picks them up.
            if let url = playbackService.buildSubtitleURL(
                itemID: item.id,
                mediaSourceID: mediaSourceID,
                streamIndex: id,
                format: stream?.codec ?? "srt"
            ) {
                player.selectSidecarSubtitle(url: url)
                subtitleCues = []
            } else {
                player.clearSubtitle()
                subtitleCues = []
            }
        } else if activePlayMethod != .transcode {
            // Embedded stream on direct play / direct stream, engine
            // streams cues from packets already flowing through the
            // main demux loop, both for text codecs (SubRip / ASS /
            // WebVTT / mov_text) and bitmap codecs (PGS / DVB / HDMV
            // PGS). No second connection, no server extraction.
            player.selectSubtitleTrack(index: id)
            subtitleCues = player.subtitleCues
        } else {
            // Transcoded session, HLS rewrites stream indices so
            // the engine can't reach the source subtitle. Fall back
            // to the legacy server-extracted SRT loader, which only
            // works for text codecs.
            player.clearSubtitle()
            subtitleCues = []
            Task { await loadSubtitles(streamIndex: id) }
        }
    }

    private static let subtitleLog = Logger(
        subsystem: "de.superuser404.Sodalite",
        category: "Subtitles"
    )

    private func loadSubtitles(streamIndex: Int) async {
        let stream = subtitleStreams.first(where: { $0.index == streamIndex })
        Self.subtitleLog.notice(
            "loadSubtitles streamIndex=\(streamIndex, privacy: .public) codec=\(stream?.codec ?? "nil", privacy: .public) lang=\(stream?.language ?? "nil", privacy: .public)"
        )

        guard let url = playbackService.buildSubtitleURL(
            itemID: item.id,
            mediaSourceID: mediaSourceID,
            streamIndex: streamIndex,
            format: "srt"
        ) else {
            Self.subtitleLog.notice("→ failed to build URL")
            return
        }

        // The first hit on a 4K UHD container can take several
        // seconds, Jellyfin lazy-extracts the sub via FFmpeg and
        // a freshly-loaded server hasn't cached anything yet. Two
        // attempts with a generous budget catches both the slow-
        // extraction case (long timeout buys it through) and the
        // odd transient (retry hits the now-cached payload).
        var request = URLRequest(url: url)
        request.timeoutInterval = 120

        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) HTTP \(http.statusCode, privacy: .public)")
                    if attempt == 2 { return }
                    continue
                }
                guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) empty payload")
                    if attempt == 2 { return }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                let cues = SRTParser.parse(content)
                if cues.isEmpty {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) parsed 0 cues from \(content.count, privacy: .public) bytes")
                    if attempt == 2 { return }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                subtitleCues = cues
                Self.subtitleLog.notice("→ loaded \(cues.count, privacy: .public) cues on attempt \(attempt, privacy: .public)")
                return
            } catch {
                Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if attempt == 2 { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Helpers

    func showControlsTemporarily() {
        showControls = true
        scheduleControlsHide()
    }

    func hideControls() {
        showControls = false
        controlsFocus = .progressBar
        trackDropdown = .none
    }

    func scheduleControlsHide() {
        controlsTimer?.cancel()
        guard isPlaying else { return }
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            hideControls()
        }
    }

    /// Detect video format from Jellyfin MediaSource metadata.
    /// Available before player.load(), no decode needed.
    private func detectVideoFormat(from source: PlaybackMediaSource) -> VideoFormat {
        guard let videoStream = source.mediaStreams?.first(where: { $0.type == .video }) else {
            return .sdr
        }

        // videoRangeType is more specific: "DOVI", "HDR10", "HDR10Plus", "HLG"
        if let rangeType = videoStream.videoRangeType?.uppercased() {
            // HDR10Plus must be checked before plain HDR10, its string
            // contains "HDR10" too, so the order matters.
            if rangeType.contains("HDR10PLUS") { return .hdr10Plus }
            if rangeType.contains("DOVI") || rangeType.contains("DOV") { return .dolbyVision }
            if rangeType.contains("HDR10") { return .hdr10 }
            if rangeType.contains("HLG") { return .hlg }
        }

        // Fallback: videoRange is "HDR" or "SDR"
        if videoStream.videoRange?.uppercased() == "HDR" { return .hdr10 }

        return .sdr
    }

    func formatSeconds(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Display Mode Switching (tvOS)

    /// Tell tvOS to switch the TV to HDR/DV/HLG mode via AVDisplayCriteria.
    /// Must be called BEFORE playback starts so the TV has time to switch.
    /// Uses public AVKit API, `UIWindow.avDisplayManager` (tvOS 11.2+).
    ///
    /// - Returns: `true` if the display will switch to HDR mode. `false` means
    ///   the caller should tone-map HDR content down to SDR during decode
    ///   (e.g. Match Content disabled, no window, or SDR content).
    @discardableResult
    func applyDisplayCriteria(format: VideoFormat, refreshRate: Float = 23.976) -> Bool {
        #if os(tvOS)
        guard #available(tvOS 17.0, *) else {
            #if DEBUG
            print("[PlayerVM] applyDisplayCriteria skipped: tvOS < 17")
            #endif
            return false
        }
        guard format != .sdr else { return false }

        guard let window = displayWindow else {
            #if DEBUG
            print("[PlayerVM] applyDisplayCriteria skipped: no window")
            #endif
            return false
        }

        let displayManager = window.avDisplayManager

        // Respect user's "Match Content" setting (Apple TV → Settings →
        // Video and Audio → Match Content → Match Dynamic Range). When
        // OFF, the system refuses to switch the display, so a
        // preferredDisplayCriteria assignment would silently no-op and
        // we'd ship HDR pixel data into an SDR-locked panel, which
        // renders as black or massively over-saturated. Tonemap path
        // is the safe fallback.
        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            #if DEBUG
            print("[PlayerVM] applyDisplayCriteria skipped: Match Content disabled in Apple TV settings, falling back to tonemap")
            #endif
            return false
        }

        let transferFunction: CFString = switch format {
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default:   kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        }

        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ]

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3840, height: 2160,
            extensions: extensions,
            formatDescriptionOut: &formatDesc
        )
        guard let desc = formatDesc else { return false }

        let criteria = AVDisplayCriteria(refreshRate: refreshRate, formatDescription: desc)
        displayManager.preferredDisplayCriteria = criteria

        #if DEBUG
        print("[PlayerVM] Display criteria SET: \(format), \(refreshRate) fps")
        #endif
        return true
        #else
        return false
        #endif
    }

    /// Wait for the TV to finish switching display modes before starting playback.
    func waitForDisplayModeSwitch() async {
        #if os(tvOS)
        guard let window = displayWindow else { return }
        let displayManager = window.avDisplayManager
        guard displayManager.isDisplayModeSwitchInProgress else { return }

        // Wait up to 5 seconds for the switch, checking periodically
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if !displayManager.isDisplayModeSwitchInProgress { break }
        }
        #endif
    }

    func resetDisplayCriteria() {
        #if os(tvOS)
        guard let window = displayWindow else { return }
        window.avDisplayManager.preferredDisplayCriteria = nil
        #if DEBUG
        print("[PlayerVM] Display criteria RESET")
        #endif
        #endif
    }

    #if os(tvOS)
    private var displayWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }
    #endif
}

enum PlayerEngineError: LocalizedError {
    case noSource
    case noURL

    var errorDescription: String? {
        switch self {
        case .noSource:
            String(
                localized: "player.error.noSource",
                defaultValue: "The server didn't return any media source for this item."
            )
        case .noURL:
            String(
                localized: "player.error.noURL",
                defaultValue: "Couldn't build a stream URL for this item."
            )
        }
    }
}

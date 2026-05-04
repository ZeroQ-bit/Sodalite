import Foundation
import AetherEngine

extension PlayerViewModel {

    func checkForNextEpisode() {
        let dur = effectiveDuration
        let remaining = dur - playbackTime
        guard dur > 0, remaining > 0, !hasFetchedNextEpisode else { return }

        // If the server gave us an outro marker (Jellyfin 10.10+ or the
        // intro-skipper plugin picked it up), start the next-episode
        // countdown as soon as the outro begins, that's usually where
        // credits roll and the episode is effectively over. Otherwise
        // fall back to the hardcoded 30 s-before-end threshold.
        let shouldFetch: Bool
        if let outro = outroSegment {
            shouldFetch = playbackTime >= outro.startSeconds
        } else {
            shouldFetch = remaining < 30
        }
        guard shouldFetch else { return }

        guard item.seriesId != nil else { return }

        hasFetchedNextEpisode = true
        Task { await fetchNextEpisode() }
    }

    private func fetchNextEpisode() async {
        guard let seriesID = item.seriesId else { return }

        // Capture identifiers up front so anything we hand to the
        // server is a snapshot of the episode we're playing right
        // now, even if `item` mutates underneath us mid-await.
        let currentID = item.id
        let currentIndex = item.indexNumber
        let currentSeasonID = item.seasonId

        // Force a progress report so Jellyfin knows we're near the
        // end. Without this, NextUp returns the current episode
        // because Jellyfin hasn't marked it as "watched" yet.
        await reportProgress()

        do {
            // Jellyfin's NextUp endpoint. Discard if it gives us the
            // current episode back (still possible even after the
            // progress report on some server configs).
            if let next = try await playbackService.getNextEpisode(
                seriesID: seriesID, userID: userID
            ), next.id != currentID {
                nextEpisode = next
                return
            }

            // Fallback: walk the season's episode list and pick the
            // one whose indexNumber is the lowest value greater than
            // the current one. This handles servers that:
            //   - return episodes out of indexNumber order
            //   - return the current episode in NextUp
            //   - have gaps in indexNumber (mid-season specials etc.)
            guard let currentSeasonID, let currentIndex else { return }
            let episodes = try await playbackService.getEpisodes(
                seriesID: seriesID, seasonID: currentSeasonID, userID: userID
            )
            let candidate = episodes
                .filter { $0.id != currentID }
                .filter { ($0.indexNumber ?? -1) > currentIndex }
                .min { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
            if let candidate {
                nextEpisode = candidate
            }
        } catch {
            #if DEBUG
            print("[NextEpisode] Fetch failed: \(error)")
            #endif
        }
    }

    /// Starts the auto-advance timer. `from` defaults to 10 s, that's
    /// the outro-based flow where we've got minutes of credits to burn
    /// through. The no-outro fallback passes the actual remaining
    /// seconds so the countdown hits 0 exactly at playback end.
    func startNextEpisodeCountdown(from seconds: Int = 10) {
        // If autoplay is disabled, still show the overlay (so the user
        // can pick next manually) but skip the timer that auto-transitions.
        guard preferences.autoplayNextEpisode else {
            isCountdownActive = false
            nextEpisodeCountdown = 0
            return
        }

        nextEpisodeCountdown = max(1, seconds)
        isCountdownActive = true
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = Task {
            while nextEpisodeCountdown > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                nextEpisodeCountdown -= 1
            }
            guard !Task.isCancelled else { return }
            // Launch in a NEW task, if we called playNextEpisode() directly,
            // cancelling nextEpisodeTimer would cancel the playback startup
            // (CancellationError in player.load → "abgebrochen").
            Task { @MainActor [weak self] in
                await self?.playNextEpisode()
            }
        }
    }

    func playNextEpisode() async {
        guard let next = nextEpisode else { return }
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false

        // Stop current
        stopProgressReporting()
        cancellables.removeAll()
        await reportStop()
        player.stop()

        // Reset state
        item = next
        startFromBeginning = true
        cachedPlaybackInfo = nil
        errorMessage = nil
        videoFormat = .sdr
        subtitleCues = []
        subtitleStreams = []
        activeSubtitleIndex = nil
        activeAudioIndex = nil
        nextEpisode = nil
        hasFetchedNextEpisode = false
        nextEpisodeCancelled = false
        nextEpisodeCountdown = 10
        isCountdownActive = false
        hasReportedStart = false
        hasStartedPlaying = false
        showControls = false
        isScrubbing = false
        controlsFocus = .progressBar
        trackDropdown = .none
        progress = 0
        playbackTime = 0
        resumePositionTicks = 0
        introSegment = nil
        outroSegment = nil
        isInsideIntro = false
        didAutoSkipCurrentIntro = false
        didAutoSkipCurrentOutro = false

        // Start new
        await startPlayback()
    }

    func cancelNextEpisode() {
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false
        isCountdownActive = false
        nextEpisodeCancelled = true
    }

    // MARK: - Season Episode Picker

    /// Loads every episode of the currently-playing item's season,
    /// sorted by indexNumber, into `seasonEpisodes`. Used by the
    /// transport-bar episode picker. Silently no-ops for items
    /// without a series + season (movies, the rare orphan episode).
    func loadSeasonEpisodes() async {
        guard let seriesID = item.seriesId,
              let seasonID = item.seasonId else {
            seasonEpisodes = []
            return
        }
        do {
            let episodes = try await playbackService.getEpisodes(
                seriesID: seriesID, seasonID: seasonID, userID: userID
            )
            seasonEpisodes = episodes.sorted { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
        } catch {
            #if DEBUG
            print("[SeasonPicker] Fetch failed: \(error)")
            #endif
            seasonEpisodes = []
        }
    }

    /// Switches playback to a specific episode in the loaded season
    /// list. Tearing down the current session and starting a fresh
    /// one mirrors the playNextEpisode flow exactly, same reset
    /// surface, same reportStop / reportStart cycle so Jellyfin's
    /// session tracking stays consistent. Bounds-checked against
    /// the current `seasonEpisodes` so a stale dropdown highlight
    /// can't crash by indexing into nothing.
    func selectEpisode(at index: Int) async {
        guard seasonEpisodes.indices.contains(index) else { return }
        let target = seasonEpisodes[index]
        guard target.id != item.id else { return }

        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false

        stopProgressReporting()
        cancellables.removeAll()
        await reportStop()
        player.stop()

        // Same reset surface playNextEpisode uses, the only
        // difference is which JellyfinItem we hand to startPlayback.
        item = target
        startFromBeginning = true
        cachedPlaybackInfo = nil
        errorMessage = nil
        videoFormat = .sdr
        subtitleCues = []
        subtitleStreams = []
        activeSubtitleIndex = nil
        activeAudioIndex = nil
        nextEpisode = nil
        hasFetchedNextEpisode = false
        nextEpisodeCancelled = false
        nextEpisodeCountdown = 10
        isCountdownActive = false
        hasReportedStart = false
        hasStartedPlaying = false
        showControls = false
        isScrubbing = false
        controlsFocus = .progressBar
        trackDropdown = .none
        progress = 0
        playbackTime = 0
        resumePositionTicks = 0
        introSegment = nil
        outroSegment = nil
        isInsideIntro = false
        didAutoSkipCurrentIntro = false
        didAutoSkipCurrentOutro = false

        await startPlayback()
    }
}

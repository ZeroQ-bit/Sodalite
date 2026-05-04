import Foundation

/// User-facing release notes. Newest first.
///
/// When you ship a new version: add a new entry at the top of
/// `entries`. The WhatsNewView modal will fire on the first launch
/// after the user updates, and the same entries are listed in
/// Settings → "What's New" for browsing later.
///
/// Keep highlights short and concrete — bullet items, not paragraphs.
/// Group by kind: `.new` for fresh features, `.improve` for noticeable
/// quality-of-life upgrades, `.fix` for user-visible bug fixes that
/// previously affected behaviour.
enum Changelog {
    static let entries: [ChangelogEntry] = [
        // MARK: 0.5.0
        ChangelogEntry(
            version: "0.5.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_5_0.dolbyVision.title",
                    "changelog.0_5_0.dolbyVision.body",
                    icon: "tv.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_5_0.hdr10Plus.title",
                    "changelog.0_5_0.hdr10Plus.body",
                    icon: "sun.max.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_5_0.subtitleRework.title",
                    "changelog.0_5_0.subtitleRework.body",
                    icon: "captions.bubble.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_5_0.chapterMarkers.title",
                    "changelog.0_5_0.chapterMarkers.body",
                    icon: "list.dash"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_5_0.errorCategories.title",
                    "changelog.0_5_0.errorCategories.body",
                    icon: "exclamationmark.triangle.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_5_0.pictureSpeed.title",
                    "changelog.0_5_0.pictureSpeed.body",
                    icon: "rectangle.expand.vertical"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_5_0.touchpadAccuracy.title",
                    "changelog.0_5_0.touchpadAccuracy.body",
                    icon: "hand.tap.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_5_0.foregroundReload.title",
                    "changelog.0_5_0.foregroundReload.body",
                    icon: "arrow.clockwise"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_5_0.staleSubtitleGhost.title",
                    "changelog.0_5_0.staleSubtitleGhost.body",
                    icon: "captions.bubble"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_5_0.supporterIcon.title",
                    "changelog.0_5_0.supporterIcon.body",
                    icon: "star.circle.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_5_0.uiAutoHide.title",
                    "changelog.0_5_0.uiAutoHide.body",
                    icon: "eye.slash.fill"
                ),
            ]
        ),
        // MARK: 0.4.1
        ChangelogEntry(
            version: "0.4.1",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_1.episodePicker.title",
                    "changelog.0_4_1.episodePicker.body",
                    icon: "list.bullet.rectangle"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_1.resumeButton.title",
                    "changelog.0_4_1.resumeButton.body",
                    icon: "play.rectangle.on.rectangle.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_1.detailLoading.title",
                    "changelog.0_4_1.detailLoading.body",
                    icon: "bolt.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_1.atmosLabel.title",
                    "changelog.0_4_1.atmosLabel.body",
                    icon: "speaker.wave.3.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_1.backgroundPause.title",
                    "changelog.0_4_1.backgroundPause.body",
                    icon: "pause.circle.fill"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_1.profileGrid.title",
                    "changelog.0_4_1.profileGrid.body",
                    icon: "person.2.circle.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_1.endOfContent.title",
                    "changelog.0_4_1.endOfContent.body",
                    icon: "checkmark.circle.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_1.polishFixes.title",
                    "changelog.0_4_1.polishFixes.body",
                    icon: "wrench.and.screwdriver.fill"
                ),
            ]
        ),
        // MARK: 0.4.0
        ChangelogEntry(
            version: "0.4.0",
            highlights: [
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_0.topshelf.title",
                    "changelog.0_4_0.topshelf.body",
                    icon: "rectangle.stack.fill"
                ),
                ChangelogHighlight(
                    .new,
                    "changelog.0_4_0.siri.title",
                    "changelog.0_4_0.siri.body",
                    icon: "waveform"
                ),
                ChangelogHighlight(
                    .improve,
                    "changelog.0_4_0.episodeImages.title",
                    "changelog.0_4_0.episodeImages.body",
                    icon: "photo.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_0.tintButtons.title",
                    "changelog.0_4_0.tintButtons.body",
                    icon: "paintpalette.fill"
                ),
                ChangelogHighlight(
                    .fix,
                    "changelog.0_4_0.cardHeights.title",
                    "changelog.0_4_0.cardHeights.body",
                    icon: "rectangle.grid.3x2.fill"
                ),
            ]
        ),
    ]

    /// The newest release. Used by WhatsNewView for the post-update
    /// modal and by the version-tracking preference to decide
    /// whether to show it.
    static var latest: ChangelogEntry? {
        entries.first
    }
}

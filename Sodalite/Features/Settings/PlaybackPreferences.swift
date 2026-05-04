import Foundation
import CoreGraphics
import Observation

/// Device-local playback preferences. Backed by `UserDefaults` so they
/// survive app restarts; not synced via CloudSyncService because most of
/// these are user-interaction tuning, not content choices.
///
/// Read/write from anywhere through `DependencyContainer.playbackPreferences`.
/// The class is `@Observable`, so SwiftUI views update automatically when a
/// setting changes.
@Observable
@MainActor
final class PlaybackPreferences {

    // MARK: - Keys

    private enum Keys {
        static let autoplayNextEpisode = "playback.autoplayNextEpisode"
        static let nextEpisodeCountdownSeconds = "playback.nextEpisodeCountdownSeconds"
        static let skipIntervalSeconds = "playback.skipIntervalSeconds"
        static let preferredAudioLanguage = "playback.preferredAudioLanguage"
        static let preferredSubtitleLanguage = "playback.preferredSubtitleLanguage"
        static let autoSkipIntro = "playback.autoSkipIntro"
        static let autoSkipOutro = "playback.autoSkipOutro"
        static let autoSubtitleForForeignAudio = "playback.autoSubtitleForForeignAudio"
        static let subtitleFontSize = "playback.subtitleFontSize"
        static let subtitleColor = "playback.subtitleColor"
        static let subtitleBackground = "playback.subtitleBackground"
        static let subtitleDelaySeconds = "playback.subtitleDelaySeconds"
        static let pictureMode = "playback.pictureMode"
    }

    // MARK: - Allowed Values

    /// 0 = disabled (countdown doesn't appear), otherwise countdown seconds.
    static let countdownChoices: [Int] = [0, 5, 10, 15]
    static let skipIntervalChoices: [Int] = [5, 10, 15, 30]

    /// Subtitle-delay choices in seconds. Negative shifts subs *earlier*
    /// (they appear before the audio line they're translating); positive
    /// shifts them *later*. Step density is finer near zero where most
    /// real-world out-of-sync issues land, wider steps further out for
    /// the rare badly-muxed track.
    static let subtitleDelayChoices: [Double] = [
        -5, -3, -2, -1.5, -1, -0.5, -0.25, 0, 0.25, 0.5, 1, 1.5, 2, 3, 5
    ]

    /// Shared language options, alphabetical by display name. ISO 639-2/B
    /// bibliographic codes (Jellyfin's convention: "deu" not "ger", "cze"
    /// not "ces", etc.).
    private static let baseLanguages: [LanguageChoice] = [
        LanguageChoice(code: "ara", short: "AR",  titleKey: "settings.playback.language.ara"),
        LanguageChoice(code: "chi", short: "ZH",  titleKey: "settings.playback.language.zho"),
        LanguageChoice(code: "cze", short: "CS",  titleKey: "settings.playback.language.ces"),
        LanguageChoice(code: "dan", short: "DA",  titleKey: "settings.playback.language.dan"),
        LanguageChoice(code: "dut", short: "NL",  titleKey: "settings.playback.language.nld"),
        LanguageChoice(code: "eng", short: "EN",  titleKey: "settings.playback.language.eng"),
        LanguageChoice(code: "fin", short: "FI",  titleKey: "settings.playback.language.fin"),
        LanguageChoice(code: "fre", short: "FR",  titleKey: "settings.playback.language.fra"),
        LanguageChoice(code: "ger", short: "DE",  titleKey: "settings.playback.language.deu"),
        LanguageChoice(code: "gre", short: "EL",  titleKey: "settings.playback.language.ell"),
        LanguageChoice(code: "heb", short: "HE",  titleKey: "settings.playback.language.heb"),
        LanguageChoice(code: "hin", short: "HI",  titleKey: "settings.playback.language.hin"),
        LanguageChoice(code: "hun", short: "HU",  titleKey: "settings.playback.language.hun"),
        LanguageChoice(code: "ind", short: "ID",  titleKey: "settings.playback.language.ind"),
        LanguageChoice(code: "ita", short: "IT",  titleKey: "settings.playback.language.ita"),
        LanguageChoice(code: "jpn", short: "JA",  titleKey: "settings.playback.language.jpn"),
        LanguageChoice(code: "kor", short: "KO",  titleKey: "settings.playback.language.kor"),
        LanguageChoice(code: "nor", short: "NO",  titleKey: "settings.playback.language.nor"),
        LanguageChoice(code: "pol", short: "PL",  titleKey: "settings.playback.language.pol"),
        LanguageChoice(code: "por", short: "PT",  titleKey: "settings.playback.language.por"),
        LanguageChoice(code: "rum", short: "RO",  titleKey: "settings.playback.language.ron"),
        LanguageChoice(code: "rus", short: "RU",  titleKey: "settings.playback.language.rus"),
        LanguageChoice(code: "spa", short: "ES",  titleKey: "settings.playback.language.spa"),
        LanguageChoice(code: "swe", short: "SV",  titleKey: "settings.playback.language.swe"),
        LanguageChoice(code: "tha", short: "TH",  titleKey: "settings.playback.language.tha"),
        LanguageChoice(code: "tur", short: "TR",  titleKey: "settings.playback.language.tur"),
        LanguageChoice(code: "ukr", short: "UK",  titleKey: "settings.playback.language.ukr"),
        LanguageChoice(code: "vie", short: "VI",  titleKey: "settings.playback.language.vie"),
    ]

    /// Audio pref dropdown, "Auto" first, then the shared alphabetical list.
    static var audioLanguageChoices: [LanguageChoice] {
        [LanguageChoice(code: nil, short: "Auto", titleKey: "settings.playback.language.auto")]
            + baseLanguages
    }

    /// Subtitle pref dropdown, same shape as audio: "Auto" first,
    /// then the alphabetical list. `nil` code lets the per-track
    /// auto-pick logic (foreign-audio detection, system language)
    /// decide; an explicit language code pins the preference.
    static var subtitleLanguageChoices: [LanguageChoice] {
        [LanguageChoice(code: nil, short: "Auto", titleKey: "settings.playback.language.auto")]
            + baseLanguages
    }

    struct LanguageChoice: Hashable, Sendable {
        /// ISO 639-2/B code as Jellyfin uses it (e.g. "deu", "eng"),
        /// or nil for "use the stream's default / current logic".
        let code: String?
        /// Short label for the chip UI ("DE", "EN", "Auto").
        let short: String
        /// Localization key for the long name ("Deutsch", "Englisch", …).
        let titleKey: String
    }

    /// Subtitle text size relative to the default. Used for both
    /// the engine's text-cue overlay and the legacy SRTParser path.
    /// Calibrated for tvOS viewing distance (3–5 m from a 55–65″ TV)
    ///, sizes land between ~32 pt (small) and ~68 pt (xlarge),
    /// roughly aligned with Apple TV's own subtitle-size
    /// accessibility range from Default to Extra Extra Large.
    enum SubtitleFontSize: String, CaseIterable, Sendable, Identifiable {
        case small, medium, large, xlarge
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.size.\(rawValue)" }
        /// Multiplier applied to the 28 pt base. The multipliers grow
        /// roughly geometrically (1.15 → 1.45 → 1.85 → 2.4) so each
        /// step up looks distinctly bigger from across the room.
        var scale: CGFloat {
            switch self {
            case .small: return 1.15
            case .medium: return 1.45
            case .large: return 1.85
            case .xlarge: return 2.4
            }
        }
    }

    /// Foreground colour for subtitle text. Three options that cover
    /// the tracks people actually mix and match (white = default,
    /// yellow = accessibility / Disney-style, grey = soften
    /// against bright HDR scenes).
    enum SubtitleColor: String, CaseIterable, Sendable, Identifiable {
        case white, yellow, gray
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.color.\(rawValue)" }
    }

    /// How the subtitle text reads against the video frame. Box is the
    /// classic semi-transparent black backing; outline draws a thin
    /// stroke around the glyphs without a fill (best when the video
    /// has heavy contrast already); none is naked text (for users who
    /// don't want anything obscuring the picture).
    enum SubtitleBackground: String, CaseIterable, Sendable, Identifiable {
        case box, outline, none
        var id: String { rawValue }
        var titleKey: String { "settings.playback.subtitle.background.\(rawValue)" }
    }

    /// How the rendered video frame fills the available player area.
    /// `original` preserves the source aspect ratio with letterbox /
    /// pillarbox bars where needed (the safe default, never hides
    /// content). `fill` zooms in and crops the overflow so the frame
    /// covers the screen edge to edge, useful for 4:3 episodes on
    /// a 16:9 TV or 2.39:1 cinemascope content where the user prefers
    /// no letterbox bars. Maps directly to AVLayerVideoGravity in the
    /// engine.
    enum PictureMode: String, CaseIterable, Sendable, Identifiable {
        case original, fill
        var id: String { rawValue }
        var titleKey: String { "settings.playback.picture.\(rawValue)" }
    }

    // MARK: - Properties

    var autoplayNextEpisode: Bool {
        didSet { store.set(autoplayNextEpisode, forKey: Keys.autoplayNextEpisode) }
    }

    var autoSkipIntro: Bool {
        didSet { store.set(autoSkipIntro, forKey: Keys.autoSkipIntro) }
    }

    var autoSkipOutro: Bool {
        didSet { store.set(autoSkipOutro, forKey: Keys.autoSkipOutro) }
    }

    var nextEpisodeCountdownSeconds: Int {
        didSet { store.set(nextEpisodeCountdownSeconds, forKey: Keys.nextEpisodeCountdownSeconds) }
    }

    var skipIntervalSeconds: Int {
        didSet { store.set(skipIntervalSeconds, forKey: Keys.skipIntervalSeconds) }
    }

    var preferredAudioLanguage: String? {
        didSet { store.set(preferredAudioLanguage, forKey: Keys.preferredAudioLanguage) }
    }

    var preferredSubtitleLanguage: String? {
        didSet { store.set(preferredSubtitleLanguage, forKey: Keys.preferredSubtitleLanguage) }
    }

    /// Auto-enable subtitles when the playing audio track isn't in the
    /// user's preferred audio language. Default ON because that mirrors
    /// the streaming-app convention (Netflix et al.), if the user wants
    /// German and the episode only has English, they almost always want
    /// German subs on top. Flip off for users who don't want subs ever.
    var autoSubtitleForForeignAudio: Bool {
        didSet { store.set(autoSubtitleForForeignAudio, forKey: Keys.autoSubtitleForForeignAudio) }
    }

    var subtitleFontSize: SubtitleFontSize {
        didSet { store.set(subtitleFontSize.rawValue, forKey: Keys.subtitleFontSize) }
    }

    var subtitleColor: SubtitleColor {
        didSet { store.set(subtitleColor.rawValue, forKey: Keys.subtitleColor) }
    }

    var subtitleBackground: SubtitleBackground {
        didSet { store.set(subtitleBackground.rawValue, forKey: Keys.subtitleBackground) }
    }

    /// Offset applied to subtitle cue timing when rendering. Positive
    /// values delay the subtitle (it appears *after* the corresponding
    /// audio); negative values pull it forward. Applied in
    /// `SubtitleOverlayView` as `effectiveTime = currentTime - delay`,
    /// so a single value covers both the engine streaming path and
    /// the legacy HTTP/SRTParser fallback.
    var subtitleDelaySeconds: Double {
        didSet { store.set(subtitleDelaySeconds, forKey: Keys.subtitleDelaySeconds) }
    }

    /// Default picture-fill mode for new playback sessions. The
    /// in-player picture button can override this for the current
    /// session without persisting, that's a transient state on
    /// PlayerViewModel, not on the prefs.
    var pictureMode: PictureMode {
        didSet { store.set(pictureMode.rawValue, forKey: Keys.pictureMode) }
    }

    // MARK: - Init

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        self.autoplayNextEpisode = store.object(forKey: Keys.autoplayNextEpisode) as? Bool ?? true
        self.autoSkipIntro = store.object(forKey: Keys.autoSkipIntro) as? Bool ?? false
        self.autoSkipOutro = store.object(forKey: Keys.autoSkipOutro) as? Bool ?? false
        self.nextEpisodeCountdownSeconds = store.object(forKey: Keys.nextEpisodeCountdownSeconds) as? Int ?? 10
        self.skipIntervalSeconds = store.object(forKey: Keys.skipIntervalSeconds) as? Int ?? 10
        self.preferredAudioLanguage = store.string(forKey: Keys.preferredAudioLanguage)
        self.preferredSubtitleLanguage = store.string(forKey: Keys.preferredSubtitleLanguage)
        self.autoSubtitleForForeignAudio = store.object(forKey: Keys.autoSubtitleForForeignAudio) as? Bool ?? true
        self.subtitleFontSize = (store.string(forKey: Keys.subtitleFontSize))
            .flatMap(SubtitleFontSize.init(rawValue:)) ?? .medium
        self.subtitleColor = (store.string(forKey: Keys.subtitleColor))
            .flatMap(SubtitleColor.init(rawValue:)) ?? .white
        self.subtitleBackground = (store.string(forKey: Keys.subtitleBackground))
            .flatMap(SubtitleBackground.init(rawValue:)) ?? .box
        self.subtitleDelaySeconds = store.object(forKey: Keys.subtitleDelaySeconds) as? Double ?? 0
        self.pictureMode = (store.string(forKey: Keys.pictureMode))
            .flatMap(PictureMode.init(rawValue:)) ?? .original
    }
}

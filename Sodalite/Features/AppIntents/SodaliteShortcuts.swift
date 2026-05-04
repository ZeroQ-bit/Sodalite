import AppIntents

/// Surfaces our intents to Siri and the Shortcuts app. On tvOS,
/// holding the Siri Remote button and saying any of these phrases
/// invokes the matching intent, Siri matches on the localized
/// phrase from the App Shortcuts catalog, so each language ships
/// its own variant in `AppShortcuts.xcstrings`.
///
/// **tvOS Siri limitation note:** custom AppIntents that aren't
/// based on a system schema (Open, Search, PlayMedia, etc.) are
/// rejected by tvOS Siri at voice-invocation time with a "the app
/// doesn't support this with Siri" error, even when the phrase
/// matches and the AppIntent metadata is correct. Only the
/// `OpenSodaliteIntent` is exposed here because "Open [App]" is
/// a system-blessed pattern that Apple handles itself via
/// LSOpenURL, not via our custom intent. `ContinueWatchingIntent`
/// stays in the codebase for the Shortcuts app on connected
/// iPhones / iPads / Macs (where custom intents do work via
/// voice), but advertising it here just produces the user-visible
/// error on tvOS Siri.
struct SodaliteShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSodaliteIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Launch \(.applicationName)",
                "Show \(.applicationName)",
            ],
            shortTitle: "Open",
            systemImageName: "play.tv"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}

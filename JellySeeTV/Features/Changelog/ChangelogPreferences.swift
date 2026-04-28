import Foundation

/// Decides whether the WhatsNewView modal fires after the splash.
///
/// Logic:
/// - Same version as last launch: `lastSeenVersion == current`.
///   Don't show.
/// - Updated to a newer version: `lastSeenVersion != current` and
///   the previous stamp is non-empty. Show the modal once, then
///   mark seen.
/// - First install ever: `lastSeenVersion` is empty AND the user
///   has never authenticated yet. Mark current version as seen
///   silently — a brand-new user shouldn't be greeted by a pop-up
///   about features they've never not had.
/// - Upgrade from a pre-Changelog version (0.3.2 or earlier):
///   `lastSeenVersion` is empty BUT the user is authenticated, so
///   they've used the app before through a previous build. Show
///   the modal so they get the same experience as users who
///   updated from a Changelog-aware version.
///
/// The `isExistingUser` discriminator is passed in by AppRouter
/// after `restoreSession()` finishes — it's based on
/// `appState.isAuthenticated`, which is the strongest signal that
/// a non-empty `lastSeenVersion` simply hasn't existed yet (rather
/// than "this is a brand-new install").
enum ChangelogPreferences {
    private static let storeKey = "changelog.lastSeenVersion"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private static var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: storeKey) ?? ""
    }

    /// Should the WhatsNewView fire on this launch?
    ///
    /// - Parameter isExistingUser: true if the user was already
    ///   authenticated when this check runs (i.e. `restoreSession`
    ///   succeeded). Used to decide whether an empty
    ///   `lastSeenVersion` is "first install" or "upgrade from a
    ///   pre-Changelog version".
    static func shouldShowOnLaunch(isExistingUser: Bool) -> Bool {
        let last = lastSeenVersion
        let current = currentVersion
        guard !current.isEmpty else { return false }
        if last == current { return false }
        if last.isEmpty {
            // No prior stamp. Show only for upgraders, not for
            // truly fresh installs.
            return isExistingUser
        }
        return true
    }

    /// Called from the modal's dismiss action and from the first-
    /// install code path. Stamps the current version so we won't
    /// show again until another upgrade lands.
    static func markCurrentSeen() {
        UserDefaults.standard.set(currentVersion, forKey: storeKey)
    }

    /// Bootstrap on first install — flips lastSeenVersion to current
    /// without showing the modal. Idempotent: a re-call after an
    /// upgrade does nothing because lastSeenVersion is already set.
    static func bootstrapIfNeeded() {
        guard lastSeenVersion.isEmpty else { return }
        markCurrentSeen()
    }

    /// Test/debug only: forget the last-seen version so the next
    /// launch fires the modal.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}

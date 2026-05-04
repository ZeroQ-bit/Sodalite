import Foundation
import os.log
import Security

/// One-shot copy of the previous JellySeeTV install's secrets into
/// the new Sodalite namespace. Runs at app startup before any other
/// keychain reader so `restoreSession()` finds the credentials in
/// the new service bucket and the user lands on their library
/// instead of the login screen.
///
/// The bridge works because `Sodalite.entitlements` claims the old
/// keychain access groups (`…JellySeeTV` + `…JellySeeTV.shared`) and
/// app group (`group.de.superuser404.JellySeeTV`) as read-only
/// migration paths, see Phase D.1 of the rename plan. As long as
/// the old JellySeeTV.app is still installed when Sodalite first
/// launches, every secret it ever wrote is reachable here.
///
/// Once the migration flag flips, the migrator is a no-op for the
/// rest of the install's lifetime. After 4–6 weeks the migration
/// access groups can be dropped from the entitlements file
/// entirely (Phase F).
enum KeychainMigrator {
    private static let log = Logger(
        subsystem: "de.superuser404.Sodalite",
        category: "KeychainMigrator"
    )

    private static let migratedFlagKey = "Sodalite.didMigrateFromJellySeeTV.v1"

    private static let oldMainService = "de.superuser404.JellySeeTV"
    private static let oldSharedService = "de.superuser404.JellySeeTV.shared"
    private static let newMainService = "de.superuser404.Sodalite"
    private static let newSharedService = "de.superuser404.Sodalite.shared"

    private static let oldAppGroup = "group.de.superuser404.JellySeeTV"
    private static let newAppGroup = "group.de.superuser404.Sodalite"

    private static let oldDeviceIDKey = "JellySeeTV_DeviceID"
    private static let newDeviceIDKey = "Sodalite_DeviceID"

    /// Runs the migration once per install. Safe to call from any
    /// thread; idempotent after the first successful run.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedFlagKey) else { return }

        let mainCopied = copyAllItems(fromService: oldMainService, toService: newMainService)
        let sharedCopied = copyAllItems(fromService: oldSharedService, toService: newSharedService)
        migrateAppGroupDeviceID()

        // Mark migration done even if no items were found, a fresh
        // install has nothing to copy and shouldn't keep probing on
        // every cold launch.
        defaults.set(true, forKey: migratedFlagKey)
        log.notice("KeychainMigrator finished: main=\(mainCopied, privacy: .public) shared=\(sharedCopied, privacy: .public)")
    }

    /// Enumerates every generic password under `fromService` and
    /// writes a copy under `toService`. Existing items at the new
    /// service are left alone, Sodalite's own writes always win
    /// over a stale migration if the user did anything mid-flight.
    @discardableResult
    private static func copyAllItems(fromService: String, toService: String) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fromService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                log.notice("KeychainMigrator probe failed: service=\(fromService, privacy: .public) status=\(status, privacy: .public)")
            }
            return 0
        }

        var copied = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data
            else { continue }

            // Don't overwrite, only fill in what's missing. Lets the
            // migrator be re-run later (debug rerun, flag reset)
            // without clobbering a more recent Sodalite write.
            if itemExists(account: account, service: toService) { continue }

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: toService,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                copied += 1
            } else {
                log.notice("KeychainMigrator copy failed: account=\(account, privacy: .public) status=\(addStatus, privacy: .public)")
            }
        }
        return copied
    }

    private static func itemExists(account: String, service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Pulls the TopShelf extension's device id out of the old app
    /// group so Jellyfin's session list keeps the same row instead
    /// of a new "Sodalite Top Shelf" entry appearing alongside the
    /// old one. Same for the main app's device id, which the OLD
    /// JellySeeTV stamped into its own UserDefaults.standard, that
    /// store is sandboxed per app and unreachable from here, so the
    /// only path is via the App Group if the OLD app mirrored it
    /// there. Sodalite's farewell build can do that mirror; if it
    /// hasn't, we just skip and let JellyfinClient generate a fresh
    /// id (Jellyfin shows a duplicate session row, harmless).
    private static func migrateAppGroupDeviceID() {
        guard let oldGroupDefaults = UserDefaults(suiteName: oldAppGroup),
              let newGroupDefaults = UserDefaults(suiteName: newAppGroup)
        else { return }

        // TopShelf-specific id (always lived in the app group).
        if newGroupDefaults.string(forKey: "topShelf.deviceID") == nil,
           let oldShelfID = oldGroupDefaults.string(forKey: "topShelf.deviceID") {
            newGroupDefaults.set(oldShelfID, forKey: "topShelf.deviceID")
        }

        // Main-app device id, only present if the farewell build
        // mirrored it into the app group. UserDefaults.standard from
        // the old app is not reachable from here.
        let standardDefaults = UserDefaults.standard
        if standardDefaults.string(forKey: newDeviceIDKey) == nil,
           let oldMainID = oldGroupDefaults.string(forKey: oldDeviceIDKey) {
            standardDefaults.set(oldMainID, forKey: newDeviceIDKey)
        }
    }
}

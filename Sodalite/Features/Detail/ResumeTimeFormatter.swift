import Foundation

/// Formats a Jellyfin `playbackPositionTicks` value (100-ns ticks) into
/// a compact resume-position label for the detail-view play buttons:
/// `12:34` for sub-hour positions, `1:02:45` once the run-time crosses
/// an hour. Sprachneutral so we can use the same string across all 26
/// shipped locales without going through the catalog.
enum ResumeTimeFormatter {
    static func format(ticks: Int) -> String? {
        guard ticks > 0 else { return nil }
        let totalSeconds = ticks / 10_000_000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

import Foundation

/// One release worth of user-visible changes. Versions are listed
/// newest-first in `Changelog.entries`; the WhatsNewView modal
/// shows the first one after a successful upgrade, the
/// ChangelogListView in Settings shows them all.
struct ChangelogEntry: Identifiable, Sendable {
    let version: String
    let highlights: [ChangelogHighlight]

    var id: String { version }
}

/// One bullet point in a changelog entry. Each highlight has a
/// kind (new / improve / fix) which selects the colour + icon
/// treatment, plus a localized title and optional description.
struct ChangelogHighlight: Identifiable, Sendable {
    let id = UUID()
    let kind: Kind
    let title: LocalizedStringResource
    let description: LocalizedStringResource?
    /// Override the kind's default SF Symbol, used when a specific
    /// feature has a more recognizable icon than the generic
    /// "sparkles" / "wrench" fallback.
    let symbolOverride: String?

    var systemImage: String {
        symbolOverride ?? kind.defaultSymbol
    }

    enum Kind: String, Sendable {
        case new
        case improve
        case fix

        var defaultSymbol: String {
            switch self {
            case .new: "sparkles"
            case .improve: "arrow.up.circle.fill"
            case .fix: "wrench.fill"
            }
        }
    }
}

extension ChangelogHighlight {
    init(
        _ kind: Kind,
        _ title: LocalizedStringResource,
        _ description: LocalizedStringResource? = nil,
        icon: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.description = description
        self.symbolOverride = icon
    }
}

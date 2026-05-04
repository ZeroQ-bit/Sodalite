import SwiftUI

/// Post-update modal showing the latest release's highlights.
/// Fires once after the user upgrades, then `ChangelogPreferences`
/// marks the version seen and the modal stays out of the way until
/// the next bump. Mirrors the visual treatment of native tvOS
/// "What's New" sheets, large title, icon row, dismiss CTA.
///
/// Layout: a single ScrollView wraps header + highlights so the
/// content can grow as long as the changelog needs and scroll
/// when it overflows the screen height. The dismiss button is
/// pinned to the safe-area inset at the bottom so it never gets
/// pushed off, no matter how many highlights ship in one release.
struct WhatsNewView: View {
    let entry: ChangelogEntry
    let onDismiss: () -> Void

    /// Namespace anchoring the focus scope so the first highlight row
    /// can declare itself as the default focus target. Without it,
    /// tvOS lands focus on whichever fokussierbare Item is closest to
    /// the leading-top corner of the modal, which on this layout is
    /// the safeAreaInset dismiss button, not the changelog the user
    /// is here to read.
    @Namespace private var focusNamespace

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                highlightsList
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .focusScope(focusNamespace)
        // Bottom edge-fade so the user sees that more content is
        // hiding below the visible viewport when the changelog runs
        // long. Same affordance Apple uses in the TV app's What's
        // New sheets, soft gradient cutoff reads as "scrollable"
        // without needing an explicit chevron hint. The fade only
        // covers the bottom 6% so a focused highlight near the
        // edge stays readable; the focus engine keeps focus
        // centered anyway, this is just a peripheral cue.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Near-opaque black so titles and rows behind the modal
        // don't bleed through and hurt readability, the previous
        // 0.85 was visibly translucent over the catalog grid.
        .background(Color.black.opacity(0.96).ignoresSafeArea())
        // Pin the Got-it CTA to the bottom edge regardless of how
        // tall the highlights list grows. The user always has a
        // visible dismiss target without having to scroll for it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dismissButton
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.96).ignoresSafeArea(edges: .bottom))
        }
        // Menu button on the Siri Remote should also dismiss, in
        // case the user reaches for the back gesture instead of
        // navigating to the Got-it button.
        .onExitCommand { onDismiss() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Text(String(localized: "changelog.modal.kicker", defaultValue: "What's New"))
                .font(.headline)
                .foregroundStyle(.tint)
                .textCase(.uppercase)
                .tracking(2)

            // Brand name + version is fixed across languages, no
            // need for a catalog entry. Splitting kicker (localized)
            // from title (verbatim) keeps the dynamic part out of
            // the LocalizedStringResource interpolation chain.
            Text("Sodalite \(entry.version)")
                .font(.system(size: 56, weight: .bold))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
        .padding(.bottom, 50)
    }

    private var highlightsList: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(entry.highlights.enumerated()), id: \.element.id) { index, highlight in
                HighlightRow(highlight: highlight)
                    .prefersDefaultFocus(index == 0, in: focusNamespace)
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 80)
        // Padding goes on the list itself instead of a trailing
        // empty Color spacer, without that, the focus engine sees
        // empty scroll space below the last row, scrolls into it
        // on the first down-press, and only routes out to the
        // safe-area-inset dismiss button on the second press.
        // Padding-as-margin keeps the visual breathing room while
        // making the down-press transition single-step.
        .padding(.bottom, 40)
    }

    private var dismissButton: some View {
        Button {
            onDismiss()
        } label: {
            Text(String(
                localized: "changelog.modal.dismiss",
                defaultValue: "Got it"
            ))
            .font(.body)
            .fontWeight(.semibold)
            .padding(.horizontal, 56)
            .padding(.vertical, 16)
        }
        .buttonStyle(SettingsTileButtonStyle())
        .padding(.vertical, 30)
    }
}

private struct HighlightRow: View {
    let highlight: ChangelogHighlight

    // @FocusState rather than @Environment(\.isFocused): the latter
    // does not propagate reliably into a plain .focusable() View on
    // tvOS, leaving the row stuck on the not-focused background and
    // the accent-tint stroke permanently hidden. Binding a real
    // FocusState to the view via .focused() updates on every focus
    // engine event, which is what we need for the visual feedback.
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            iconBubble

            VStack(alignment: .leading, spacing: 4) {
                Text(highlight.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                if let description = highlight.description {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isFocused ? .white.opacity(0.15) : .white.opacity(0.05))
        )
        // Same accent-tint stroke + lift treatment SettingsTileButtonStyle
        // uses for actionable tiles, so focused rows read as the same
        // visual primitive across the app.
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(isFocused ? 1 : 0)
        )
        .scaleEffect(isFocused ? 1.03 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 15, y: 8)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        // Each row needs to be focusable for the tvOS focus engine
        // to step through them, otherwise the scroll view has no
        // anchor inside it and a long changelog can't be scrolled
        // by the user.
        .focusable()
        .focused($isFocused)
    }

    private var iconBubble: some View {
        ZStack {
            Circle()
                .fill(tintForKind.opacity(0.18))
            Image(systemName: highlight.systemImage)
                .font(.title2)
                .foregroundStyle(tintForKind)
        }
        .frame(width: 60, height: 60)
    }

    private var tintForKind: Color {
        // Map the kind to a recognizable colour without relying on
        // the user's accent, these are status indicators, not
        // brand surfaces.
        switch highlight.kind {
        case .new: return .blue
        case .improve: return .green
        case .fix: return .orange
        }
    }
}

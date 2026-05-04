import SwiftUI

struct GlassActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    /// Optional inline secondary label, used by the detail-view
    /// resume button to surface "S1E5 · 12:34" without breaking row
    /// height. Renders in caption + 0.75 opacity so it reads as
    /// supporting metadata, not a competing title.
    var subtitle: String? = nil
    /// Optional 0…1 progress overlay drawn behind the button label.
    /// Used by the resume button to mirror Apple TV+'s convention of
    /// painting the user's progress through the title across the
    /// resume tile in the active accent. nil suppresses the overlay
    /// entirely (fresh content, no progress to show).
    var progressFraction: Double? = nil
    /// When true, the label is replaced with a spinner and the
    /// button is disabled. Used while the host view is still
    /// resolving which content the action will play, e.g. the
    /// series detail's play button waits for getNextUp before it
    /// can decide between "Abspielen" and "Fortsetzen + S1E5".
    /// Showing a placeholder is visually quieter than letting the
    /// title flip mid-render.
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView()
                        .frame(minWidth: 80)
                } else {
                    Image(systemName: systemImage)
                        .font(.body)
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .buttonStyle(GlassButtonStyle(
            isProminent: isProminent,
            progressFraction: progressFraction
        ))
        .disabled(isLoading)
    }
}

struct GlassButtonStyle: ButtonStyle {
    var isProminent: Bool = false
    /// 0…1, ignored when nil. Drives the resume-progress fill rendered
    /// behind the label. The bar wears the accent tint so it picks up
    /// whatever colour the user has selected for the rest of the UI.
    var progressFraction: Double? = nil
    @Environment(\.isFocused) private var isFocused

    /// A tile that wears a progress overlay drops its prominent fill
    ///, the accent-coloured backdrop drowned out the accent-coloured
    /// progress capsule and the bar read as a barely-visible shade
    /// difference. Falling back to the neutral grey fill the other
    /// detail-row buttons use lets the progress capsule pop in full
    /// tint colour against the muted base.
    private var effectivelyProminent: Bool {
        isProminent && (progressFraction ?? 0) <= 0
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(backgroundFill)

                    if let fraction = progressFraction, fraction > 0 {
                        GeometryReader { geo in
                            Capsule()
                                .fill(.tint.opacity(isFocused ? 0.95 : 0.85))
                                .frame(width: geo.size.width * CGFloat(min(1.0, fraction)))
                        }
                        // Shape the inner fill to the outer capsule so
                        // a fraction near 1.0 doesn't bleed past the
                        // pill's rounded edge on either side.
                        .clipShape(Capsule())
                    }
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.08 : (configuration.isPressed ? 0.95 : 1.0))
            .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
            .animation(.easeInOut(duration: 0.15), value: isFocused)
    }

    private var backgroundFill: AnyShapeStyle {
        if effectivelyProminent {
            return AnyShapeStyle(isFocused ? Color.accentColor.opacity(0.9) : Color.accentColor.opacity(0.7))
        }
        return AnyShapeStyle(isFocused ? .white.opacity(0.2) : .white.opacity(0.1))
    }
}

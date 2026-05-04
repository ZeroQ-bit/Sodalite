import SwiftUI
import AetherEngine

/// Renders the subtitle cues active at the current playback time on top
/// of the video. Two body kinds:
///
/// - **Text**, a centered, semi-transparent black box with white text.
///   At most one text cue is active at a time in practice (FFmpeg's
///   text decoders merge same-time rects into one cue), but the layout
///   tolerates more.
/// - **Image**, a bitmap with normalised position (PGS / DVB / HDMV).
///   Multiple bitmap cues can overlap (signs/songs at the top while
///   dialogue stays at the bottom), so we render every active one.
struct SubtitleOverlayView: View {
    let cues: [SubtitleCue]
    let currentTime: Double
    /// User-selected text size, applied as a multiplier on top of the
    /// base `.title3` font. Picked up from PlaybackPreferences.
    let fontSize: PlaybackPreferences.SubtitleFontSize
    /// User-selected foreground colour for text cues. Bitmap cues
    /// (PGS / DVB) ignore this, the colour is baked into the
    /// graphic by the source.
    let textColor: PlaybackPreferences.SubtitleColor
    /// Background style for text cues (box / outline / none).
    let background: PlaybackPreferences.SubtitleBackground
    /// Subtitle timing offset in seconds. Positive = subs appear later
    /// than the audio they translate; negative = subs appear earlier.
    /// Applied to both text and image cues so the user's setting works
    /// regardless of which decoder produced the cue.
    let delaySeconds: Double

    var body: some View {
        GeometryReader { geo in
            // `Color.clear` fills the proposed size so the overlay
            // covers the same rect as the underlying video layer
            // (otherwise SwiftUI may collapse the ZStack to the
            // largest child's frame and the .offset math suddenly
            // anchors against a small box). `.overlay(alignment:
            // .topLeading)` makes (0, 0) of the inner views the
            // top-left corner of that rect, so subtitle absolute
            // positions become a straight `.offset(x: pixels, y:
            // pixels)` from there.
            Color.clear
                .overlay(alignment: .topLeading) {
                    ForEach(activeCues, id: \.id) { cue in
                        switch cue.body {
                        case .text(let text):
                            textOverlay(text, in: geo.size)
                        case .image(let image):
                            imageOverlay(image, in: geo.size)
                        }
                    }
                }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Text branch

    private func textOverlay(_ text: String, in size: CGSize) -> some View {
        // Pinned to the bottom-centre of the video rect with a
        // ~80pt safe-area gap. Width is capped so long lines wrap
        // with horizontal margins on either side.
        let maxWidth = max(0, size.width - 240)
        // tvOS .title3 lands around 24-29pt depending on platform
        // metrics; the user-selected scale multiplies that for
        // small/medium/large/xlarge.
        let basePoints: CGFloat = 28
        let pointSize = basePoints * fontSize.scale
        return styledText(text, pointSize: pointSize)
            .frame(maxWidth: maxWidth)
            .frame(width: size.width, alignment: .center)
            .position(x: size.width / 2, y: size.height - 100)
            .transition(.opacity)
    }

    /// Compose the text view itself, font + colour + the chosen
    /// background style (box / outline / none). Outline is drawn by
    /// stacking eight nudged copies in black behind the foreground
    /// text; the system has no per-character stroke modifier on tvOS.
    @ViewBuilder
    private func styledText(_ text: String, pointSize: CGFloat) -> some View {
        let foreground = foregroundColor
        let baseFont = Font.system(size: pointSize, weight: .semibold)

        switch background {
        case .box:
            Text(text)
                .font(baseFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .outline:
            ZStack {
                ForEach(outlineOffsets, id: \.self) { offset in
                    Text(text)
                        .font(baseFont)
                        .foregroundStyle(.black)
                        .multilineTextAlignment(.center)
                        .offset(x: offset.x, y: offset.y)
                }
                Text(text)
                    .font(baseFont)
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        case .none:
            Text(text)
                .font(baseFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
        }
    }

    private var foregroundColor: Color {
        switch textColor {
        case .white: return .white
        case .yellow: return Color(red: 1.0, green: 0.86, blue: 0.0)
        case .gray: return Color(white: 0.85)
        }
    }

    /// Eight-direction offsets for the outline-style background. Two
    /// pixels at TV viewing distance reads as a solid edge without
    /// looking like a dropshadow.
    private static let outlineOffsets: [CGPoint] = [
        CGPoint(x: -2, y: -2), CGPoint(x: 0, y: -2), CGPoint(x: 2, y: -2),
        CGPoint(x: -2, y:  0),                       CGPoint(x: 2, y:  0),
        CGPoint(x: -2, y:  2), CGPoint(x: 0, y:  2), CGPoint(x: 2, y:  2),
    ]
    private var outlineOffsets: [CGPoint] { Self.outlineOffsets }

    // MARK: - Image branch

    private func imageOverlay(_ image: SubtitleImage, in size: CGSize) -> some View {
        // Normalised position is in source-video coordinates. The
        // outer Color.clear fills the GeometryReader rect, the
        // overlay's alignment is .topLeading, so an .offset of
        // (x_pixels, y_pixels) from the top-left puts the image's
        // top-left corner at exactly (x_pixels, y_pixels) on the
        // video.
        let frameW = image.position.width * size.width
        let frameH = image.position.height * size.height
        let originX = image.position.minX * size.width
        let originY = image.position.minY * size.height

        return Image(decorative: image.cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: frameW, height: frameH)
            .offset(x: originX, y: originY)
    }

    // MARK: - Active-cue lookup

    /// Returns every cue whose time range contains `currentTime`.
    /// Cues are sorted by `startTime` (engine + sidecar both insert in
    /// order), so we binary-search for the first cue starting after
    /// now and walk back collecting any whose endTime hasn't passed.
    private var activeCues: [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        // Apply user's delay offset. delay > 0 means subs should
        // appear LATER than they would by default, so the cue at
        // [10..12] is "perceived" as [11..13] for delay = +1.
        // Equivalently, look up at (currentTime - delay), at audio
        // time 11.0 we want the cue whose intrinsic start was 10.0.
        let lookupTime = currentTime - delaySeconds
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].startTime > lookupTime {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        var result: [SubtitleCue] = []
        var i = lo - 1
        while i >= 0, cues[i].startTime <= lookupTime {
            if cues[i].endTime >= lookupTime {
                result.append(cues[i])
            }
            i -= 1
        }
        return result.reversed()
    }
}

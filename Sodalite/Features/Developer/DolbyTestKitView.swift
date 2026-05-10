import SwiftUI
import UIKit
import AVKit
import Combine
import Compression
import CoreMedia
import CoreVideo
import AetherEngine

struct DolbyTestKitView: View {
    @State private var selectedSignal: DolbyBrowserTestSignal?
    @Namespace private var focusNamespace

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.bottom, 24)

                ForEach(DolbyBrowserTestSignal.Group.displayOrder) { group in
                    sectionHeader(group.title)
                    ForEach(DolbyBrowserTestSignal.signals(in: group)) { signal in
                        Button {
                            guard signal.isPlayable else { return }
                            selectedSignal = signal
                        } label: {
                            DolbySignalRow(signal: signal)
                        }
                        .buttonStyle(SettingsTileButtonStyle())
                        .disabled(!signal.isPlayable)
                        .prefersDefaultFocus(signal.id == DolbyBrowserTestSignal.defaultFocusedSignalID, in: focusNamespace)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 60)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusScope(focusNamespace)
        .overlay {
            DolbyTestPlayerLauncher(signal: $selectedSignal)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .toolbar(.hidden, for: .tabBar)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dolby Browser Test Kit")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("MP4 source rows use Sodalite's Aether native-remux path. Clear HLS uses AVPlayer as a known baseline. DASH and DRM manifests are listed for coverage.")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 980, alignment: .leading)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 24)
            .padding(.bottom, 4)
    }
}

private struct DolbySignalRow: View {
    let signal: DolbyBrowserTestSignal

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: signal.icon)
                .font(.title2)
                .frame(width: 56, alignment: .center)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(signal.title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(signal.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(signal.actionTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(20)
    }
}

private struct DolbyTestPlayerLauncher: UIViewControllerRepresentable {
    @Binding var signal: DolbyBrowserTestSignal?

    func makeUIViewController(context: Context) -> DolbyTestPlayerLauncherHostController {
        DolbyTestPlayerLauncherHostController()
    }

    func updateUIViewController(_ host: DolbyTestPlayerLauncherHostController, context: Context) {
        if let signal, host.presentedViewController == nil {
            let selection = $signal
            let player = DolbyTestPlayerHostController(signal: signal) {
                host.dismiss(animated: false) {
                    selection.wrappedValue = nil
                }
            }
            player.modalPresentationStyle = .fullScreen
            host.present(player, animated: false)
        } else if signal == nil, host.presentedViewController != nil {
            host.dismiss(animated: false)
        }
    }
}

private final class DolbyTestPlayerLauncherHostController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}

@MainActor
private final class DolbyTestPlayerHostController: UIViewController {
    private let signal: DolbyBrowserTestSignal
    private let state: DolbyTestPlayerState
    private let onDismiss: () -> Void
    private let player = DependencyContainer.playerEngine

    private var nativePlayer: NativeAVPlayer?
    private var hostedVideoLayer: CALayer?
    private var startTask: Task<Void, Never>?
    private var hasStarted = false

    init(signal: DolbyBrowserTestSignal, onDismiss: @escaping () -> Void) {
        self.signal = signal
        self.state = DolbyTestPlayerState(signal: signal)
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let overlay = UIHostingController(rootView: DolbyTestPlayerOverlay(state: state))
        overlay.view.backgroundColor = .clear
        overlay.view.isUserInteractionEnabled = false
        addChild(overlay)
        view.addSubview(overlay.view)
        overlay.view.frame = view.bounds
        overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.didMove(toParent: self)

        addPressGesture(.menu, action: #selector(menuPressed))
        addPressGesture(.playPause, action: #selector(playPausePressed))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        startTask = Task { await startPlayback() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedVideoLayer?.frame = view.bounds
        CATransaction.commit()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed || isMovingFromParent else { return }
        stopPlayback()
    }

    private func startPlayback() async {
        LogTap.shared.clear()
        LogTap.shared.note("[DolbyTest] \(signal.title) route=\(signal.route.logName)")
        LogTap.shared.note("[DolbyTest] display capabilities: \(DisplayCapabilities.summary) rawHDRModes=\(AVPlayer.availableHDRModes.rawValue)")
        state.status = "Preparing display"

        let displayFormat = preferredDisplayFormat(for: signal)
        let displaySwitched = applyDisplayCriteria(format: displayFormat, refreshRate: Float(signal.frameRate))
        if displaySwitched {
            await waitForDisplayModeSwitch()
        }

        do {
            switch signal.route {
            case .aetherSourceMP4, .aetherSourceMP4VideoOnly:
                state.status = "Fetching source MP4"
                let sourceURL = try await DolbySourceMP4Resolver.localMP4URL(for: signal)
                state.status = "Starting Aether native remux"
                let localURL = try player.startNativeVideoSession(url: sourceURL, includeAudio: signal.route.includeAudio)
                LogTap.shared.note("[DolbyTest] native session url=\(localURL.absoluteString)")
                await logNativeMasterPlaylist(url: localURL)
                startNativePlayer(url: localURL)
            case .nativeSourceMP4:
                state.status = "Fetching source MP4"
                let sourceURL = try await DolbySourceMP4Resolver.localMP4URL(for: signal)
                state.status = "Starting AVPlayer direct MP4"
                LogTap.shared.note("[DolbyTest] direct MP4 url=\(sourceURL.absoluteString)")
                startNativePlayer(url: sourceURL)
            case .nativeHLS:
                state.status = "Starting AVPlayer HLS"
                startNativePlayer(url: signal.url)
            }

            state.status = "Playing"
            state.isPlaying = true
        } catch {
            let nsError = error as NSError
            let message = "\(nsError.domain)/\(nsError.code) \(nsError.localizedDescription)"
            LogTap.shared.note("[DolbyTest] failed: \(message)")
            state.status = "Failed"
            state.errorMessage = message
        }
    }

    private func startNativePlayer(url: URL) {
        let native = NativeAVPlayer()
        nativePlayer = native
        swapVideoLayer(to: native.playerLayer)
        native.load(url: url, startPosition: nil)
        native.play()
    }

    private func logNativeMasterPlaylist(url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else {
                LogTap.shared.note("[DolbyTest] master.m3u8 bytes=\(data.count) (non-UTF8)")
                return
            }
            LogTap.shared.note("[DolbyTest] master.m3u8 bytes=\(data.count)")
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                LogTap.shared.note("[DolbyTest] master: \(line)")
            }
        } catch {
            let nsError = error as NSError
            LogTap.shared.note("[DolbyTest] master.m3u8 fetch failed: \(nsError.domain)/\(nsError.code) \(nsError.localizedDescription)")
        }
    }

    private func swapVideoLayer(to layer: CALayer) {
        hostedVideoLayer?.removeFromSuperlayer()
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        hostedVideoLayer = layer
    }

    private func addPressGesture(_ type: UIPress.PressType, action: Selector) {
        let tap = UITapGestureRecognizer(target: self, action: action)
        tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(tap)
    }

    @objc private func menuPressed() {
        hostedVideoLayer?.removeFromSuperlayer()
        stopPlayback()
        onDismiss()
    }

    @objc private func playPausePressed() {
        guard state.errorMessage == nil else { return }
        nativePlayer?.toggle()
        state.isPlaying.toggle()
        state.status = state.isPlaying ? "Playing" : "Paused"
    }

    private func stopPlayback() {
        startTask?.cancel()
        startTask = nil
        player.onVideoLayerReplaced = nil
        nativePlayer?.tearDown()
        nativePlayer = nil
        player.stopNativeVideoSession()
        player.stop()
        resetDisplayCriteria()
        state.isPlaying = false
    }

    @discardableResult
    private func applyDisplayCriteria(format: VideoFormat, refreshRate: Float) -> Bool {
        #if os(tvOS)
        guard #available(tvOS 17.0, *) else { return false }
        guard let window = displayWindow else { return false }

        let displayManager = window.avDisplayManager
        guard displayManager.isDisplayCriteriaMatchingEnabled else {
            LogTap.shared.note("[DolbyTest] Match Content disabled; display criteria skipped")
            return false
        }

        let transferFunction: CFString = switch format {
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        default: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        }

        let extensions: NSDictionary = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: transferFunction,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ]

        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 3840,
            height: 2160,
            extensions: extensions,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return false }

        displayManager.preferredDisplayCriteria = AVDisplayCriteria(
            refreshRate: refreshRate,
            formatDescription: formatDescription
        )
        LogTap.shared.note("[DolbyTest] display criteria set format=\(format) fps=\(refreshRate)")
        return true
        #else
        return false
        #endif
    }

    private func preferredDisplayFormat(for signal: DolbyBrowserTestSignal) -> VideoFormat {
        switch signal.profileID {
        case "p84":
            return .hlg
        case "p5":
            return .dolbyVision
        case "p81":
            return DisplayCapabilities.supportsDolbyVision ? .dolbyVision : .hdr10
        default:
            return .dolbyVision
        }
    }

    private func waitForDisplayModeSwitch() async {
        #if os(tvOS)
        guard let window = displayWindow else { return }
        let displayManager = window.avDisplayManager
        guard displayManager.isDisplayModeSwitchInProgress else { return }
        for _ in 0..<50 {
            try? await Task.sleep(for: .milliseconds(100))
            if !displayManager.isDisplayModeSwitchInProgress { break }
        }
        #endif
    }

    private func resetDisplayCriteria() {
        #if os(tvOS)
        guard let window = displayWindow else { return }
        window.avDisplayManager.preferredDisplayCriteria = nil
        #endif
    }

    #if os(tvOS)
    private var displayWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first
    }
    #endif
}

private final class DolbyTestPlayerState: ObservableObject {
    let signal: DolbyBrowserTestSignal
    @Published var status = "Starting"
    @Published var isPlaying = false
    @Published var errorMessage: String?

    init(signal: DolbyBrowserTestSignal) {
        self.signal = signal
    }
}

private struct DolbyTestPlayerOverlay: View {
    @ObservedObject var state: DolbyTestPlayerState
    @ObservedObject private var tap = LogTap.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.signal.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("\(state.signal.route.title)  |  \(state.status)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let error = state.errorMessage {
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Menu closes. Play/Pause toggles playback.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.black.opacity(0.6))
            )
            .padding(.leading, 60)
            .padding(.top, 60)

            if LogTap.isDiagnosticBuild {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tap.lines.suffix(14).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 16, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.black.opacity(0.55))
                )
                .padding(.leading, 60)
                .padding(.top, 190)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

private struct DolbyBrowserTestSignal: Identifiable {
    enum Group: String, CaseIterable, Identifiable {
        case clearDash
        case clearHLS
        case fairPlayHLS
        case cencDash
        case cbcsDash
        case mp4Packages

        var id: String { rawValue }

        static let displayOrder: [Group] = [
            .mp4Packages,
            .clearHLS,
            .clearDash,
            .fairPlayHLS,
            .cencDash,
            .cbcsDash
        ]

        var title: String {
            switch self {
            case .clearDash: return "Clear MPEG-DASH"
            case .clearHLS: return "Clear HLS"
            case .fairPlayHLS: return "FairPlay HLS"
            case .cencDash: return "CENC DASH"
            case .cbcsDash: return "CBCS DASH"
            case .mp4Packages: return "MP4 Source Packages"
            }
        }

        var formatLabel: String {
            switch self {
            case .clearDash, .cencDash, .cbcsDash: return "MPEG-DASH"
            case .clearHLS, .fairPlayHLS: return "HLS"
            case .mp4Packages: return "MP4 ZIP"
            }
        }

        var pathComponent: String {
            switch self {
            case .clearDash, .clearHLS: return "clear"
            case .fairPlayHLS, .cbcsDash: return "cbcs"
            case .cencDash: return "cenc"
            case .mp4Packages: return "source_mp4s"
            }
        }

        var isPlayable: Bool {
            switch self {
            case .clearHLS, .mp4Packages: return true
            case .clearDash, .fairPlayHLS, .cencDash, .cbcsDash: return false
            }
        }
    }

    enum Route {
        case aetherSourceMP4
        case aetherSourceMP4VideoOnly
        case nativeSourceMP4
        case nativeHLS

        var title: String {
            switch self {
            case .aetherSourceMP4: return "Aether source MP4"
            case .aetherSourceMP4VideoOnly: return "Aether source MP4 video-only"
            case .nativeSourceMP4: return "AVPlayer source MP4"
            case .nativeHLS: return "AVPlayer HLS"
            }
        }

        var logName: String {
            switch self {
            case .aetherSourceMP4: return "aether-source-mp4"
            case .aetherSourceMP4VideoOnly: return "aether-source-mp4-video-only"
            case .nativeSourceMP4: return "native-source-mp4"
            case .nativeHLS: return "native-hls"
            }
        }

        var includeAudio: Bool {
            switch self {
            case .aetherSourceMP4, .nativeSourceMP4, .nativeHLS: return true
            case .aetherSourceMP4VideoOnly: return false
            }
        }
    }

    private struct Profile {
        let id: String
        let title: String
        let doviProfile: Int
        let blCompatibilityID: Int?
    }

    let id: String
    let title: String
    let subtitle: String
    let actionTitle: String
    let icon: String
    let url: URL
    let group: Group
    let profileID: String?
    let frameRate: Int
    let isPlayable: Bool
    let route: Route
    let fairPlayLicenseURL: URL?

    static let allSignals: [DolbyBrowserTestSignal] = Group.displayOrder.flatMap { signals(in: $0) }
    static let defaultFocusedSignalID = "sourceMP4Direct.p81.24"

    static func signals(in group: Group) -> [DolbyBrowserTestSignal] {
        switch group {
        case .mp4Packages:
            return profiles.flatMap { profile in
                frameRates.flatMap { frameRate in
                    let url = URL(string: "\(baseURL)/source_mp4s/\(frameRate)fps.zip")!
                    return [
                        DolbyBrowserTestSignal(
                            id: "sourceMP4Direct.\(profile.id).\(frameRate)",
                            title: "\(profile.title) \(frameRate) fps SD source MP4 direct",
                            subtitle: "Rivulet-style direct MP4 handoff to AVPlayer, bypasses Aether local HLS",
                            actionTitle: "Direct",
                            icon: "play.rectangle",
                            url: url,
                            group: group,
                            profileID: profile.id,
                            frameRate: frameRate,
                            isPlayable: true,
                            route: .nativeSourceMP4,
                            fairPlayLicenseURL: nil
                        ),
                        DolbyBrowserTestSignal(
                            id: "sourceMP4.\(profile.id).\(frameRate)",
                            title: "\(profile.title) \(frameRate) fps SD source MP4",
                            subtitle: "Range-extracts the matching SD MP4 from \(frameRate)fps.zip for Aether native remux",
                            actionTitle: "Fetch",
                            icon: "film.stack",
                            url: url,
                            group: group,
                            profileID: profile.id,
                            frameRate: frameRate,
                            isPlayable: true,
                            route: .aetherSourceMP4,
                            fairPlayLicenseURL: nil
                        ),
                        DolbyBrowserTestSignal(
                            id: "sourceMP4VideoOnly.\(profile.id).\(frameRate)",
                            title: "\(profile.title) \(frameRate) fps SD source MP4 video-only",
                            subtitle: "Same local remux without audio, isolates AVPlayer video manifest handling",
                            actionTitle: "Video",
                            icon: "film",
                            url: url,
                            group: group,
                            profileID: profile.id,
                            frameRate: frameRate,
                            isPlayable: true,
                            route: .aetherSourceMP4VideoOnly,
                            fairPlayLicenseURL: nil
                        )
                    ]
                }
            }
        default:
            return profiles.flatMap { profile in
                frameRates.map { frameRate in
                    signal(group: group, profile: profile, frameRate: frameRate)
                }
            }
        }
    }

    private static func signal(group: Group, profile: Profile, frameRate: Int) -> DolbyBrowserTestSignal {
        let fileName = group.formatLabel == "HLS" ? "master.m3u8" : "dash.mpd"
        let url = URL(string: "\(baseURL)/\(group.pathComponent)/\(profile.id)/\(frameRate)/\(fileName)")!
        let fairPlayURL = group == .fairPlayHLS ? fairPlayLicenseURL(profileID: profile.id, frameRate: frameRate) : nil
        let route: Route = .nativeHLS
        let subtitle: String = {
            switch group {
            case .clearDash:
                return "\(profile.title) MPEG-DASH manifest, listed for coverage"
            case .clearHLS:
                return "\(profile.title) Dolby Vision, Dolby Atmos + AAC, routed through AVPlayer"
            case .fairPlayHLS:
                return "\(profile.title) Dolby Vision, FairPlay license listed"
            case .cencDash:
                return "\(profile.title) Dolby Vision, Widevine / PlayReady CENC"
            case .cbcsDash:
                return "\(profile.title) Dolby Vision, Widevine / PlayReady CBCS"
            case .mp4Packages:
                return "ZIP package with MP4 source files"
            }
        }()

        return DolbyBrowserTestSignal(
            id: "\(group.rawValue).\(profile.id).\(frameRate)",
            title: "\(profile.title) \(frameRate) fps \(group.formatLabel)",
            subtitle: subtitle,
            actionTitle: group.isPlayable ? "Play" : group == .clearDash ? "MPD" : "DRM",
            icon: group == .clearDash ? "arrow.triangle.2.circlepath" : "play.tv",
            url: url,
            group: group,
            profileID: profile.id,
            frameRate: frameRate,
            isPlayable: group.isPlayable,
            route: route,
            fairPlayLicenseURL: fairPlayURL
        )
    }

    private static func fairPlayLicenseURL(profileID: String, frameRate: Int) -> URL? {
        guard let assetID = fairPlayAssetIDs["\(profileID).\(frameRate)"] else { return nil }
        return URL(string: "https://fps.ezdrm.com/api/licenses/auth?pX=9d69c5&assetID=\(assetID)")
    }

    private static let baseURL = "https://ott.dolby.com/browser_test_kit"
    private static let frameRates = [24, 25, 30, 50, 120]
    private static let profiles = [
        Profile(id: "p5", title: "P5", doviProfile: 5, blCompatibilityID: nil),
        Profile(id: "p81", title: "P8.1", doviProfile: 8, blCompatibilityID: 1),
        Profile(id: "p84", title: "P8.4", doviProfile: 8, blCompatibilityID: 4)
    ]
    private static let fairPlayAssetIDs = [
        "p5.24": "dd90eccc-a5eb-428a-aca5-ae461c3338f6",
        "p5.25": "d1d4a3e9-ea8f-4e23-a15b-82feb5a2430f",
        "p5.30": "80158719-86d8-42cc-b31a-91aea3abe163",
        "p5.50": "16cd6b40-3c2b-4ff3-9220-0f196b4fb460",
        "p5.120": "5b35e4e8-65fb-4353-af4a-353eea4a7e38",
        "p81.24": "03854522-021f-45bb-a51c-93e7a63d3db9",
        "p81.25": "5d80b941-c5d5-4f16-ad84-dbcb2f882380",
        "p81.30": "a31817d1-4b3e-4848-9e89-721e9fb8e510",
        "p81.50": "3b6400af-eaa1-4429-ab00-d0e73d3e213d",
        "p81.120": "b4458035-5218-4887-a183-abc5635d5792",
        "p84.24": "14ad9b7f-f9c5-417b-9449-7e558550f5d5",
        "p84.25": "fc580d34-2183-419d-8e9d-9d209de994a1",
        "p84.30": "d3a44087-f8dc-4ed6-b0dc-b60e8715eabb",
        "p84.50": "87225b2a-1440-41a5-9c52-6ef956d7f177",
        "p84.120": "340230ef-d2d7-4656-b89b-bf98b14ac1f9"
    ]
}

private enum DolbySourceMP4Error: LocalizedError {
    case missingPackage
    case missingContentLength
    case invalidZip(String)
    case entryNotFound
    case unsupportedCompression(UInt16)
    case decompressionFailed
    case httpStatus(Int, URL)

    var errorDescription: String? {
        switch self {
        case .missingPackage:
            return "This Dolby row does not have a source MP4 package."
        case .missingContentLength:
            return "The Dolby ZIP package did not report a content length."
        case .invalidZip(let detail):
            return "Invalid ZIP package: \(detail)"
        case .entryNotFound:
            return "Could not find the matching SD MP4 inside the Dolby ZIP package."
        case .unsupportedCompression(let method):
            return "Unsupported ZIP compression method \(method)."
        case .decompressionFailed:
            return "Could not decompress the selected Dolby MP4."
        case .httpStatus(let status, let url):
            return "HTTP \(status) while fetching \(url.lastPathComponent)."
        }
    }
}

private enum DolbySourceMP4Resolver {
    private struct ZipEntry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int64
    }

    static func localMP4URL(for signal: DolbyBrowserTestSignal) async throws -> URL {
        guard signal.group == .mp4Packages else { throw DolbySourceMP4Error.missingPackage }

        let cacheURL = try cacheFileURL(for: signal)
        if fileExists(at: cacheURL) {
            LogTap.shared.note("[DolbyTest] source MP4 cache hit: \(cacheURL.lastPathComponent)")
            return cacheURL
        }

        let zipURL = signal.url
        LogTap.shared.note("[DolbyTest] reading ZIP directory: \(zipURL.lastPathComponent)")
        let contentLength = try await fetchContentLength(for: zipURL)
        let tailSize = min(Int64(2 * 1024 * 1024), contentLength)
        let tail = try await fetchData(from: zipURL, range: (contentLength - tailSize)...(contentLength - 1))
        let entries = try parseCentralDirectory(tail: tail, zipContentLength: contentLength)
        guard let entry = entries.first(where: { matches($0.name, signal: signal) }) else {
            throw DolbySourceMP4Error.entryNotFound
        }

        LogTap.shared.note("[DolbyTest] extracting \(entry.name)")
        let dataOffset = try await payloadOffset(for: entry, in: zipURL)
        let compressed = try await fetchData(
            from: zipURL,
            range: dataOffset...(dataOffset + Int64(entry.compressedSize) - 1)
        )
        let mp4 = try decompress(compressed, method: entry.method, uncompressedSize: entry.uncompressedSize)

        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try mp4.write(to: cacheURL, options: [.atomic])
        LogTap.shared.note("[DolbyTest] source MP4 ready: \(cacheURL.lastPathComponent)")
        return cacheURL
    }

    private static func cacheFileURL(for signal: DolbyBrowserTestSignal) throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("DolbyBrowserTestKit", isDirectory: true)
        let profile = signal.profileID ?? "source"
        return directory.appendingPathComponent("\(profile)-\(signal.frameRate)-SD.mp4")
    }

    private static func fileExists(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return false
        }
        return size > 0
    }

    private static func matches(_ name: String, signal: DolbyBrowserTestSignal) -> Bool {
        guard name.contains("/SD/"),
              name.hasSuffix(".mp4"),
              !name.contains("/._") else {
            return false
        }

        let lower = name.lowercased()
        switch signal.profileID {
        case "p5":
            return lower.contains("dovi")
        case "p81":
            return lower.contains("hdr10-p8.1")
        case "p84":
            return lower.contains("hlg-p8.4")
        default:
            return false
        }
    }

    private static func fetchContentLength(for url: URL) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DolbySourceMP4Error.missingContentLength
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DolbySourceMP4Error.httpStatus(http.statusCode, url)
        }
        if http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        if let value = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int64(value) {
            return length
        }
        throw DolbySourceMP4Error.missingContentLength
    }

    private static func fetchData(from url: URL, range: ClosedRange<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard http.statusCode == 206 || http.statusCode == 200 else {
            throw DolbySourceMP4Error.httpStatus(http.statusCode, url)
        }
        return data
    }

    private static func parseCentralDirectory(tail: Data, zipContentLength: Int64) throws -> [ZipEntry] {
        guard let eocd = tail.lastIndex(ofSignature: 0x06054b50) else {
            throw DolbySourceMP4Error.invalidZip("missing end of central directory")
        }

        let totalEntries = Int(tail.uint16(at: eocd + 10))
        let centralDirectoryOffset = Int64(tail.uint32(at: eocd + 16))
        let tailStart = zipContentLength - Int64(tail.count)
        var offset = Int(centralDirectoryOffset - tailStart)
        guard offset >= 0, offset < tail.count else {
            throw DolbySourceMP4Error.invalidZip("central directory outside fetched tail")
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(totalEntries)
        for _ in 0..<totalEntries {
            guard offset + 46 <= tail.count,
                  tail.uint32(at: offset) == 0x02014b50 else {
                throw DolbySourceMP4Error.invalidZip("bad central directory entry")
            }
            let method = tail.uint16(at: offset + 10)
            let compressedSize = Int(tail.uint32(at: offset + 20))
            let uncompressedSize = Int(tail.uint32(at: offset + 24))
            let fileNameLength = Int(tail.uint16(at: offset + 28))
            let extraLength = Int(tail.uint16(at: offset + 30))
            let commentLength = Int(tail.uint16(at: offset + 32))
            let localHeaderOffset = Int64(tail.uint32(at: offset + 42))
            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= tail.count else {
                throw DolbySourceMP4Error.invalidZip("truncated entry name")
            }
            let name = String(decoding: tail[nameStart..<nameEnd], as: UTF8.self)
            entries.append(
                ZipEntry(
                    name: name,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )
            offset = nameEnd + extraLength + commentLength
        }
        return entries
    }

    private static func payloadOffset(for entry: ZipEntry, in url: URL) async throws -> Int64 {
        let header = try await fetchData(from: url, range: entry.localHeaderOffset...(entry.localHeaderOffset + 128))
        guard header.count >= 30, header.uint32(at: 0) == 0x04034b50 else {
            throw DolbySourceMP4Error.invalidZip("bad local file header")
        }
        let fileNameLength = Int64(header.uint16(at: 26))
        let extraLength = Int64(header.uint16(at: 28))
        return entry.localHeaderOffset + 30 + fileNameLength + extraLength
    }

    private static func decompress(_ data: Data, method: UInt16, uncompressedSize: Int) throws -> Data {
        switch method {
        case 0:
            return data
        case 8:
            var output = Data(count: uncompressedSize)
            let decoded = output.withUnsafeMutableBytes { outputBuffer in
                data.withUnsafeBytes { inputBuffer in
                    compression_decode_buffer(
                        outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        uncompressedSize,
                        inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }
            guard decoded == uncompressedSize else {
                throw DolbySourceMP4Error.decompressionFailed
            }
            return output
        default:
            throw DolbySourceMP4Error.unsupportedCompression(method)
        }
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func lastIndex(ofSignature signature: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        var offset = count - 4
        while offset >= 0 {
            if uint32(at: offset) == signature {
                return offset
            }
            if offset == 0 { break }
            offset -= 1
        }
        return nil
    }
}

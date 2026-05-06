import Foundation
import Combine

/// Captures lines written to `stdout` (where `print(...)` lands) and
/// publishes the most recent matching lines for an in-app overlay.
/// Diagnostic-only, lets TestFlight testers screenshot what the
/// engine logged during playback when they have no Mac to pair with
/// Console.app. Also re-emits captured bytes back onto the original
/// stdout file descriptor so Xcode console / OSLog forwarding stay
/// intact.
final class LogTap: ObservableObject {

    static let shared = LogTap()

    /// Build is "diagnostic" when running under the debugger (DEBUG)
    /// or shipped via TestFlight (sandbox receipt). App Store builds
    /// stay silent so end users never see the overlay.
    static let isDiagnosticBuild: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    @Published private(set) var lines: [String] = []

    /// Patterns we consider interesting. The pipe sees every print
    /// from every part of the process, including SwiftUI / OS noise,
    /// so we filter to engine + player diagnostics only.
    private let patterns = [
        "[VideoDecoder]",
        "[SoftwareVideoDecoder]",
        "[Renderer]",
        "[AetherEngine]",
        "[Demuxer]",
        "[PlayerVM]",
        "[HLSAudio]",
        "[HLSAudioEngine]"
    ]

    private let maxLines = 80
    private let pipe = Pipe()
    private var originalStdoutFD: Int32 = -1
    private var residualBuffer = ""
    private let appendQueue = DispatchQueue(label: "com.sodalite.logtap.append")

    private init() {
        guard Self.isDiagnosticBuild else { return }
        installPipe()
    }

    private func installPipe() {
        // Force stdout line-buffered so each print() flushes through
        // the pipe immediately. Default is fully-buffered when stdout
        // isn't a tty, which would buffer ~4 KB before we see anything.
        setvbuf(stdout, nil, _IOLBF, 0)

        // Save the original stdout fd so we can echo back to it.
        // Without this, redirecting fd 1 onto the pipe also redirects
        // anything Xcode or os_log forwarding watches.
        originalStdoutFD = dup(fileno(stdout))

        // Replace fd 1 with the pipe's write end.
        dup2(pipe.fileHandleForWriting.fileDescriptor, fileno(stdout))

        let originalFD = originalStdoutFD
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Echo back to the saved original fd so the Xcode console
            // and any external OSLog stream keep showing what the app
            // wrote. Best-effort, ignore the return.
            if originalFD >= 0 {
                _ = data.withUnsafeBytes { buf -> Int in
                    guard let base = buf.baseAddress else { return 0 }
                    return write(originalFD, base, data.count)
                }
            }

            guard let chunk = String(data: data, encoding: .utf8) else { return }
            self?.appendQueue.async { [weak self] in
                self?.ingest(chunk)
            }
        }
    }

    /// Buffer partial lines: a single print() may arrive split across
    /// reads if it crosses an internal boundary, so accumulate and
    /// only commit complete \n-terminated lines.
    private func ingest(_ chunk: String) {
        residualBuffer += chunk
        var committed: [String] = []
        while let nlIndex = residualBuffer.firstIndex(of: "\n") {
            let line = String(residualBuffer[..<nlIndex])
            residualBuffer = String(residualBuffer[residualBuffer.index(after: nlIndex)...])
            if patterns.contains(where: { line.contains($0) }) {
                committed.append(line)
            }
        }
        guard !committed.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lines.append(contentsOf: committed)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    /// Wipe the buffer (e.g. between playback sessions so the next
    /// test starts with a clean slate).
    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.lines.removeAll()
        }
    }
}

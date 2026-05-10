import Foundation
import Combine

/// Ring buffer of recent diagnostic log lines, surfaced into the
/// player overlay so a TestFlight beta tester can screenshot what
/// the engine reported during playback when they have no Mac to
/// pair with Console.app.
///
/// Lines arrive via two paths:
///   - `AetherEngine.EngineLog.handler` (preferred) for engine prints
///     that go through the explicit broadcaster.
///   - Direct `LogTap.shared.note(_:)` calls from host code (e.g.
///     PlayerViewModel) for things the engine doesn't see.
///
/// We deliberately do **not** redirect `stdout` via `dup2` any more,
/// the previous approach was unreliable on tvOS Release builds where
/// stdout is silently null-redirected when no debugger is attached.
final class LogTap: ObservableObject {

    static let shared = LogTap()

    /// Whether the diagnostic overlay should be mounted at all.
    /// Always on under the debugger (DEBUG), on for sandbox-receipt
    /// builds (TestFlight), off for App Store builds so end users
    /// never see a developer overlay.
    static let isDiagnosticBuild: Bool = {
        #if DEBUG
        return true
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    @Published private(set) var lines: [String] = []

    private let maxLines = 80

    private init() {}

    /// Append one line to the overlay. Safe to call from any thread.
    /// Long lines are truncated when rendered in the overlay (the
    /// view applies `lineLimit(1)` + tail truncation).
    func note(_ line: String) {
        #if DEBUG
        if line.hasPrefix("[NativeAVPlayer]") || line.hasPrefix("[DolbyTest]") {
            print(line)
        }
        #endif
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lines.append(line)
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

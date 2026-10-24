import Foundation

/// Owns the Node sidecar process: launches it, learns its loopback port, watches for death and
/// restarts it. The sidecar holds no user-visible state, so a restart is invisible apart from a
/// short "service not ready" state.
@MainActor
final class SidecarManager {
    enum State: Equatable {
        case idle
        case starting
        case ready(port: Int)
        case failed(String)

        var port: Int? {
            if case .ready(let port) = self { return port }
            return nil
        }
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    private var process: Process?
    private var handshakePipe: Pipe?
    private var stderrPipe: Pipe?
    private var buffer = ""
    private var restartAttempt = 0
    private var restartTask: Task<Void, Never>?
    private var isStopping = false

    private let sidecarDirectory: URL
    private let supportDirectory: URL

    init(sidecarDirectory: URL, supportDirectory: URL) {
        self.sidecarDirectory = sidecarDirectory
        self.supportDirectory = supportDirectory
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil, !isStopping else { return }
        state = .starting

        let node = Self.nodeExecutable(in: sidecarDirectory)
        let wrapper = sidecarDirectory.appendingPathComponent("wrapper.js")

        guard FileManager.default.fileExists(atPath: wrapper.path) else {
            state = .failed("找不到 sidecar（wrapper.js）")
            return
        }

        let process = Process()
        process.executableURL = node
        process.arguments = [wrapper.path]
        process.currentDirectoryURL = sidecarDirectory
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice

        let handshake = Pipe()
        let errors = Pipe()
        process.standardOutput = handshake
        process.standardError = errors
        handshakePipe = handshake
        stderrPipe = errors

        handshake.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            guard let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.consume(text) }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                self?.handleTermination(status: proc.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed("无法启动 sidecar：\(error.localizedDescription)")
            return
        }

        // If the handshake never arrives the service is unusable; fail visibly rather than hang.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, self.state == .starting else { return }
            self.state = .failed("sidecar 启动超时")
            self.stopProcess()
        }
    }

    func stop() {
        isStopping = true
        restartTask?.cancel()
        stopProcess()
        state = .idle
    }

    private func stopProcess() {
        handshakePipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        buffer = ""
    }

    // MARK: - Handshake

    private func consume(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        let marker = "BBMUSIC_PORT "
        guard line.hasPrefix(marker), let port = Int(line.dropFirst(marker.count)) else { return }
        restartAttempt = 0
        state = .ready(port: port)
    }

    private func handleTermination(status: Int32) {
        process = nil
        guard !isStopping else { return }
        state = .failed("sidecar 已退出（状态码 \(status)）")
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        guard restartAttempt < 3 else { return }
        // 1s / 2s / 5s: quick enough to be invisible for a crash, slow enough not to spin.
        let delays: [UInt64] = [1, 2, 5]
        let delay = delays[min(restartAttempt, delays.count - 1)]
        restartAttempt += 1
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled, !self.isStopping else { return }
            self.start()
        }
    }

    // MARK: - Environment

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["NODE_ENV"] = "test"  // keep the upstream from binding its own all-interfaces listener
        env["QQ_DISABLE_UPDATE_CHECK"] = "1"
        env["AUTO_OPEN_EXPLORER"] = "0"
        env["LOG_LEVEL"] = "warn"
        // A stable secret + state path keeps the QQ session alive across sidecar restarts and app
        // launches, so the user does not have to scan a QR code again.
        env["QQ_SESSION_SECRET"] = Self.sessionSecret(supportDirectory: supportDirectory)
        env["QQ_AUTH_SESSION_PATH"] = supportDirectory
            .appendingPathComponent("qq-session.json").path
        env["QQ_AUTH_STATE_PATH"] = supportDirectory
            .appendingPathComponent("qq-device.json").path
        // Do not set PORT=0: the upstream validates the port as > 0 before it ever binds, and it
        // exits on a bad config. The wrapper binds port 0 itself and reports the real port back.
        env.removeValue(forKey: "PORT")
        return env
    }

    /// A per-install secret stored next to the session file. It never leaves this Mac; its only job
    /// is encrypting the QQ session at rest.
    private static func sessionSecret(supportDirectory: URL) -> String {
        let url = supportDirectory.appendingPathComponent("sidecar-secret")
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing.count >= 32 {
            return existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // `SystemRandomNumberGenerator` is the standard library's cryptographically secure source —
        // it draws from the same kernel pool `SecRandomCopyBytes` does, without pulling in Security
        // (which the app no longer uses for anything, including the keychain).
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        try? secret.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return secret
    }

    /// Node ships inside the app bundle. In development we fall back to the Node that built it, so
    /// `swift run` works before the bundle is assembled.
    private static func nodeExecutable(in sidecarDirectory: URL) -> URL {
        let bundled = sidecarDirectory.appendingPathComponent("node/bin/node")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }
}

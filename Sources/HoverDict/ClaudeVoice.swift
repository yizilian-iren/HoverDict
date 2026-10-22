import AVFoundation
import Foundation

/// The user's own "Claude voice": the Qwen3-TTS clone served on home4070 (voice-tts project,
/// `POST /v1/speech` on its 127.0.0.1:8770, the same service Agent Deck's Sound & voice uses).
/// HoverDict reaches it through an ssh tunnel it opens itself (local port 18770), caches each
/// clip on disk, and reports failure so the caller can fall back to Google / the system voice
/// (home4070 off, or the service stopped for gaming). About 1.2–1.5 s for a fresh word.
final class ClaudeVoice {

    static let shared = ClaudeVoice()

    /// ssh host running the voice service; `defaults write com.hoverdict.HoverDict
    /// HoverDict.voiceHost <host>` to change, empty to turn the voice off.
    private var host: String {
        UserDefaults.standard.string(forKey: "HoverDict.voiceHost") ?? "home4070"
    }
    private let localPort = 18770
    private var tunnel: Process?
    private var player: AVAudioPlayer?
    private var requestSeq = 0
    private var inFlightKey: String?
    /// After the voice couldn't be reached, use the fallback straight away for a while
    /// instead of waiting on ssh for every word.
    private var unreachableUntil = Date.distantPast
    private let cacheRoot: URL
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private init() {
        cacheRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoverDict/tts", isDirectory: true)
    }

    /// Speak `text`; `fallback` runs (on the main thread) when the voice can't be had.
    func play(_ text: String, language: TypedLanguage, fallback: @escaping () -> Void) {
        let flightKey = language.rawValue + ":" + TTSPlayer.key(for: text)
        // Same word asked again while its clip is still being fetched: let that one finish.
        if inFlightKey == flightKey { return }
        inFlightKey = nil
        requestSeq += 1
        let seq = requestSeq
        player?.stop()
        guard !host.isEmpty, Date() >= unreachableUntil else { fallback(); return }

        let dir = cacheRoot.appendingPathComponent("claude-\(language.rawValue)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(TTSPlayer.key(for: text) + ".wav")
        if FileManager.default.fileExists(atPath: file.path) {
            playClip(file, ifCurrent: seq)
            return
        }
        inFlightKey = flightKey
        Task {
            let data = await self.fetch(text, language: language)
            await MainActor.run {
                if self.inFlightKey == flightKey { self.inFlightKey = nil }
                guard seq == self.requestSeq else { return }
                guard let data else {
                    self.unreachableUntil = Date().addingTimeInterval(60)
                    fallback()
                    return
                }
                try? data.write(to: file, options: .atomic)
                self.playClip(file, ifCurrent: seq)
            }
        }
    }

    func stop() {
        inFlightKey = nil
        requestSeq += 1
        player?.stop()
    }

    func shutdown() {
        tunnel?.terminate()
        tunnel = nil
    }

    private func playClip(_ url: URL, ifCurrent seq: Int) {
        guard seq == requestSeq, let clip = try? AVAudioPlayer(contentsOf: url) else { return }
        player = clip
        clip.play()
    }

    private func fetch(_ text: String, language: TypedLanguage) async -> Data? {
        if let data = await request(text, language: language) { return data }
        // Tunnel not up yet (or it dropped): open it, give ssh a moment, try once more.
        guard await MainActor.run(body: { self.openTunnel() }) else { return nil }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if await health() { break }
        }
        return await request(text, language: language)
    }

    private func request(_ text: String, language: TypedLanguage) async -> Data? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(localPort)/v1/speech")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "voice": "claude-kuudere", "format": "wav",
                                   "language": language.serviceLanguage]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    private func health() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(localPort)/health")!)
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    @MainActor
    private func openTunnel() -> Bool {
        if let tunnel, tunnel.isRunning { return true }
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                         "-o", "ConnectTimeout=4", "-o", "ServerAliveInterval=30",
                         "-L", "\(localPort):127.0.0.1:8770", host]
        ssh.standardOutput = FileHandle.nullDevice
        ssh.standardError = FileHandle.nullDevice
        do {
            try ssh.run()
        } catch {
            NSLog("HoverDict: voice tunnel failed to start: \(error)")
            return false
        }
        tunnel = ssh
        return true
    }
}

private extension TypedLanguage {
    /// voice_server.py's language names.
    var serviceLanguage: String {
        switch self {
        case .zh: "chinese"
        case .ja: "japanese"
        case .en: "english"
        }
    }
}

import AVFoundation
import Foundation

/// Speaks words in Google Translate's TTS voice.
///
/// Clips are fetched from Google's public `translate_tts` endpoint the first time a word
/// is spoken, cached to disk as mp3, and replayed straight from disk (offline) ever after
/// — so the cache grows toward the words you actually read. If the network is down or the
/// fetch fails, it falls back to the system speech synthesizer so a word is never dropped.
final class TTSPlayer {

    static let shared = TTSPlayer()

    /// Cached clips: `<key>.mp3` in
    /// ~/Library/Application Support/HoverDict/tts/google/
    private let cacheDir: URL

    /// Retained for the lifetime of playback, else it deallocates mid-clip.
    private var player: AVAudioPlayer?
    /// Identifies the most recently requested word. A slow network fetch that only
    /// finishes after the cursor has moved on is discarded instead of played late.
    private var requestSeq = 0

    private let session = URLSession(configuration: .ephemeral)

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cacheDir = support
            .appendingPathComponent("HoverDict", isDirectory: true)
            .appendingPathComponent("tts", isDirectory: true)
            .appendingPathComponent("google", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Map a word to its cache filename stem: trimmed, lowercased, path-unsafe chars swapped.
    static func key(for word: String) -> String {
        var k = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        k = k.replacingOccurrences(of: "/", with: "_")
        k = k.replacingOccurrences(of: ":", with: "_")
        return k
    }

    /// Speak `word`: play the cached clip if present, else fetch it from Google, cache it,
    /// and play it. On any failure run `fallback` (system voice). Non-blocking.
    func play(_ word: String, fallback: @escaping () -> Void) {
        let key = Self.key(for: word)
        guard !key.isEmpty else { return }

        requestSeq += 1
        let seq = requestSeq
        // Stop whatever clip might still be playing from the previous word.
        player?.stop()

        let url = cacheDir.appendingPathComponent(key + ".mp3")
        if FileManager.default.fileExists(atPath: url.path) {
            playClip(at: url, ifCurrent: seq)
            return
        }

        fetch(word: word) { [weak self] data in
            guard let self else { return }
            guard let data, !data.isEmpty else {
                DispatchQueue.main.async { if seq == self.requestSeq { fallback() } }
                return
            }
            try? data.write(to: url, options: .atomic)
            DispatchQueue.main.async { self.playClip(at: url, ifCurrent: seq) }
        }
    }

    /// Play the clip at `url`, but only if `seq` is still the most recent request (the
    /// user hasn't moved on to another word in the meantime).
    private func playClip(at url: URL, ifCurrent seq: Int) {
        guard seq == requestSeq, let clip = try? AVAudioPlayer(contentsOf: url) else { return }
        player = clip
        clip.play()
    }

    /// Hit Google's translate_tts endpoint for a single word; hands back mp3 bytes, or nil
    /// on any non-audio / error response.
    private func fetch(word: String, completion: @escaping (Data?) -> Void) {
        var comps = URLComponents(string: "https://translate.google.com/translate_tts")!
        comps.queryItems = [
            .init(name: "ie", value: "UTF-8"),
            .init(name: "client", value: "tw-ob"),  // keyless web-client mode
            .init(name: "tl", value: "en"),
            .init(name: "q", value: word),
        ]
        guard let url = comps.url else { completion(nil); return }
        var req = URLRequest(url: url)
        // Google rejects requests that don't look like a browser.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        session.dataTask(with: req) { data, resp, _ in
            let http = resp as? HTTPURLResponse
            let ok = http?.statusCode == 200
            let isAudio = http?.value(forHTTPHeaderField: "Content-Type")?
                .contains("audio") ?? false
            completion(ok && isAudio ? data : nil)
        }.resume()
    }
}

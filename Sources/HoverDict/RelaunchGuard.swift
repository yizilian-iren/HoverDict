import Foundation

/// Keeps the stuck-OCR relaunch from turning into a loop: if OCR is stuck again soon
/// after relaunching, a fresh process won't fix it (2026-10-23: a new signature made each
/// process relaunch every ~20 s, so the model compile never finished).
enum RelaunchGuard {

    /// Relaunches counted within this window…
    static let window: TimeInterval = 10 * 60
    /// …at most this many; one more stuck pass is left alone.
    static let maxRelaunches = 2

    /// The relaunch history to save when a relaunch at `now` is allowed; nil when there
    /// were already `maxRelaunches` in the last `window`.
    static func allow(history: [Date], now: Date) -> [Date]? {
        let recent = history.filter { $0 <= now && now.timeIntervalSince($0) < window }
        guard recent.count < maxRelaunches else { return nil }
        return recent + [now]
    }
}

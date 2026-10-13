import AppKit

/// Notices a press of Shift (alone) while the popup is up, to expand / collapse it.
///
/// A modifier on its own can't be a Carbon hot key, and a global key monitor needs the
/// Accessibility permission; reading the current modifier state can be done without
/// either, so this polls it — only while `isActive` says the popup is showing.
final class ShiftWatcher {

    /// Shift went down (with no ⌘ / ⌥ / ⌃). Main thread.
    var onPress: (() -> Void)?
    /// Polling stops by itself once this turns false.
    var isActive: () -> Bool = { false }

    private var timer: Timer?
    private var wasDown = false

    func start() {
        guard timer == nil else { return }
        // Shift already held when the popup appeared doesn't count as a press.
        wasDown = Self.shiftAlone()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isActive() else { stop(); return }
        let down = Self.shiftAlone()
        if down && !wasDown { onPress?() }
        wasDown = down
    }

    private static func shiftAlone() -> Bool {
        NSEvent.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift
    }
}

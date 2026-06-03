import AppKit

/// Watches global mouse movement and fires a callback once the cursor has been
/// *still* for `stillInterval` seconds (debounce). This avoids re-running the
/// capture+OCR pipeline on every pixel of movement and prevents the panel from
/// flickering while the user is just moving the mouse across the screen.
final class MouseMonitor {

    /// Called when the cursor has stopped moving for `stillInterval`.
    /// The point is in AppKit **global screen coordinates** (points, bottom-left origin).
    var onCursorStill: ((CGPoint) -> Void)?

    private let stillInterval: TimeInterval
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var debounceTimer: Timer?

    init(stillInterval: TimeInterval = 0.2) {
        self.stillInterval = stillInterval
    }

    func start() {
        // Global monitor: delivers mouse-moved events that are headed to *other*
        // applications. Because we run as an accessory app, this is exactly the
        // "user is hovering over Claude / a browser / VS Code" case we care about.
        //
        // IMPORTANT: a global monitor for .mouseMoved does NOT require the
        // Accessibility permission. (Only CGEvent taps / key monitoring do.)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.scheduleFire()
        }

        // Local monitor: covers the rare case where the pointer is over one of our
        // own (non-key) windows; keeps the debounce timing consistent. It must
        // return the event so normal dispatch continues.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.scheduleFire()
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    /// Restart the debounce countdown on every movement; only when it fires
    /// (cursor idle for `stillInterval`) do we trigger the pipeline.
    private func scheduleFire() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: stillInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            // NSEvent.mouseLocation: current cursor position in AppKit global
            // screen coordinates — points, origin bottom-left of the primary display.
            self.onCursorStill?(NSEvent.mouseLocation)
        }
    }
}

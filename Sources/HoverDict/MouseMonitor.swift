import AppKit

/// Watches global mouse movement and clicks.
///
/// - Hover mode: fires `onCursorStill` once the cursor has been still for
///   `stillInterval` seconds (debounce).
/// - Click mode: fires `onClick` on left-mouse-down (no debounce).
///
/// Debouncing avoids re-running the capture+OCR pipeline on every pixel of
/// movement and prevents the panel from flickering while the user is just
/// moving the mouse across the screen.
final class MouseMonitor {

    /// Called when the cursor has stopped moving for `stillInterval`.
    /// The point is in AppKit **global screen coordinates** (points, bottom-left origin).
    var onCursorStill: ((CGPoint) -> Void)?

    /// Called on every mouse-moved event (no debounce). Used to dismiss the popup.
    var onMouseMoved: ((CGPoint) -> Void)?

    /// Called on left-mouse-down. Same coordinate space as `onCursorStill`.
    var onClick: ((CGPoint) -> Void)?

    /// Debounce interval; settable at runtime (takes effect on the next mouse move).
    var stillInterval: TimeInterval
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var debounceTimer: Timer?

    init(stillInterval: TimeInterval = 0.2) {
        self.stillInterval = stillInterval
    }

    func start() {
        // Global monitor: delivers mouse events headed to *other* applications.
        // Because we run as an accessory app, this is exactly the
        // "user is hovering/clicking over Claude / a browser / VS Code" case.
        //
        // IMPORTANT: a global monitor for mouse moved/down does NOT require the
        // Accessibility permission. (Only CGEvent taps / key monitoring do.)
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleMove()
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.fireClick()
        }

        // Local monitor: covers the rare case where the pointer is over one of our
        // own (non-key) windows; keeps timing consistent. Must return the event so
        // normal dispatch continues.
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMove()
            return event
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.fireClick()
            return event
        }
    }

    func stop() {
        if let g = globalMoveMonitor { NSEvent.removeMonitor(g); globalMoveMonitor = nil }
        if let l = localMoveMonitor { NSEvent.removeMonitor(l); localMoveMonitor = nil }
        if let g = globalClickMonitor { NSEvent.removeMonitor(g); globalClickMonitor = nil }
        if let l = localClickMonitor { NSEvent.removeMonitor(l); localClickMonitor = nil }
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    private func handleMove() {
        let point = NSEvent.mouseLocation
        onMouseMoved?(point)
        scheduleFire()
    }

    /// Restart the debounce countdown on every movement; only when it fires
    /// (cursor idle for `stillInterval`) do we trigger the hover pipeline.
    private func scheduleFire() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: stillInterval, repeats: false) { [weak self] _ in
            guard let self else { return }
            // NSEvent.mouseLocation: current cursor position in AppKit global
            // screen coordinates — points, origin bottom-left of the primary display.
            self.onCursorStill?(NSEvent.mouseLocation)
        }
    }

    private func fireClick() {
        // Cancel any pending hover fire so a click doesn't also produce a
        // delayed hover lookup of the same point.
        debounceTimer?.invalidate()
        debounceTimer = nil
        onClick?(NSEvent.mouseLocation)
    }
}

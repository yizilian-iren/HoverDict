import AppKit
import ScreenCaptureKit
import CoreGraphics

/// Result of one capture: the bitmap plus the *exact* global rectangle it covers,
/// which the coordinate mapper needs to turn Vision boxes back into screen coordinates.
struct CaptureResult {
    /// Captured pixels. Size = `captureRectGlobal.size * screenScale`.
    let cgImage: CGImage
    /// The region the image covers, in AppKit **global** coordinates
    /// (points, bottom-left origin). This is the clamped/actual rect, not the requested one.
    let captureRectGlobal: CGRect
    /// backingScaleFactor of the display we captured from (1.0 or 2.0…).
    let screenScale: CGFloat
}

/// Captures a small region around the cursor using ScreenCaptureKit's one-shot
/// `SCScreenshotManager` (macOS 14+). One-shot screenshots fit the "fire after the
/// cursor is still" model far better than a continuous `SCStream` — lower latency,
/// no idle GPU/power cost.
final class ScreenCapturer {

    /// How large a region (in *points*) to grab around the cursor.
    /// 260×100 pt → on a 2x Retina display that's 520×200 px, which Vision's
    /// .accurate path OCRs comfortably. Bigger = more context but slower.
    private let captureSize = CGSize(width: 260, height: 100)

    /// Cache of SCDisplay objects keyed by CGDirectDisplayID, refreshed when the
    /// screen layout changes. `SCShareableContent.current` is relatively expensive,
    /// so we avoid calling it on every hover.
    private var displayCache: [CGDirectDisplayID: SCDisplay] = [:]

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenLayoutChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenLayoutChanged() {
        displayCache.removeAll()
    }

    /// Capture a region centered on `cursorGlobal` (AppKit global, bottom-left, points).
    /// Returns nil if the cursor isn't on a known screen or capture fails.
    func capture(around cursorGlobal: CGPoint) async -> CaptureResult? {
        guard let screen = screenContaining(point: cursorGlobal) else { return nil }

        // 1) Desired capture rect in AppKit global coords (bottom-left), centered on cursor.
        let desired = CGRect(
            x: cursorGlobal.x - captureSize.width / 2,
            y: cursorGlobal.y - captureSize.height / 2,
            width: captureSize.width,
            height: captureSize.height
        )

        // 2) Clamp to the screen so the region stays inside the display bounds
        //    (SCStreamConfiguration.sourceRect must lie within the display).
        let captureRectGlobal = desired.intersection(screen.frame)
        guard !captureRectGlobal.isNull, captureRectGlobal.width > 1, captureRectGlobal.height > 1 else {
            return nil
        }

        // 3) Resolve the SCDisplay for this NSScreen.
        guard let displayID = screen.displayID,
              let scDisplay = await display(for: displayID) else {
            return nil
        }

        // 4) Convert the global (bottom-left) rect → display-local (top-left) points.
        let sourceRect = sourceRect(forGlobalRect: captureRectGlobal, on: screen)
        let scale = screen.backingScaleFactor

        // 5) Configure and grab.
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        // Output buffer in *pixels* = points * scale, so the image is native-resolution
        // and maps 1:1 (linearly) onto sourceRect with matching aspect ratio.
        config.width = Int((sourceRect.width * scale).rounded())
        config.height = Int((sourceRect.height * scale).rounded())
        config.scalesToFit = false
        config.showsCursor = false           // don't bake the arrow cursor over the text
        config.captureResolution = .best
        config.ignoreShadowsDisplay = true

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return CaptureResult(cgImage: image, captureRectGlobal: captureRectGlobal, screenScale: scale)
        } catch {
            NSLog("HoverDict: capture failed: \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    private func screenContaining(point: CGPoint) -> NSScreen? {
        // NSScreen.frame is in the same AppKit global (bottom-left) space as the point.
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func display(for id: CGDirectDisplayID) async -> SCDisplay? {
        if let cached = displayCache[id] { return cached }
        do {
            let content = try await SCShareableContent.current
            for d in content.displays { displayCache[d.displayID] = d }
            return displayCache[id]
        } catch {
            NSLog("HoverDict: SCShareableContent failed: \(error)")
            return nil
        }
    }

    /// Convert a rect in AppKit global coordinates (points, bottom-left origin) into
    /// the coordinate space `SCStreamConfiguration.sourceRect` expects:
    /// points, relative to the **display's top-left** corner.
    ///
    /// Two steps, and both are classic off-by-screen bug sources — read carefully:
    ///   a) Make the rect display-local by subtracting the screen's global origin.
    ///   b) Flip the Y axis from bottom-left to top-left within the display. The
    ///      rect's *top* edge in bottom-left space is `local.maxY`; that same edge
    ///      measured from the top is `screenHeight - local.maxY`, which becomes the
    ///      new origin.y (because a top-left rect's origin is its top edge).
    private func sourceRect(forGlobalRect rect: CGRect, on screen: NSScreen) -> CGRect {
        let local = CGRect(
            x: rect.minX - screen.frame.minX,
            y: rect.minY - screen.frame.minY,
            width: rect.width,
            height: rect.height
        )
        let topLeftY = screen.frame.height - local.maxY
        return CGRect(x: local.minX, y: topLeftY, width: local.width, height: local.height)
    }
}

extension NSScreen {
    /// The CGDirectDisplayID backing this NSScreen (used to match an SCDisplay).
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return deviceDescription[key] as? CGDirectDisplayID
    }
}

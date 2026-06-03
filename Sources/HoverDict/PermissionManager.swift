import AppKit
import CoreGraphics

/// Screen Recording (TCC) permission gate.
///
/// A screen-OCR take-word tool needs the **Screen Recording** permission. This permission
/// is bound to the app's bundle id + code signature, which is exactly why we ship a real
/// `.app` bundle (see Scripts/build_app.sh) rather than running a bare SwiftPM binary.
///
/// Note: mouse-move monitoring via `NSEvent.addGlobalMonitorForEvents` does **not** require
/// the Accessibility permission (only CGEvent taps / keyboard monitoring do). So Phase 1
/// needs Screen Recording only.
enum PermissionManager {

    /// Non-prompting check: is Screen Recording already granted?
    static func hasScreenRecordingPermission() -> Bool {
        // CGPreflightScreenCaptureAccess() returns true only if access is already granted,
        // and never shows a prompt — ideal for a startup gate.
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system's Screen Recording prompt the first time it's called.
    /// Returns the (already-known) current grant state synchronously.
    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        // The first call shows the system prompt and registers this app in
        // System Settings → Privacy & Security → Screen Recording.
        CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings directly at the Screen Recording pane.
    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

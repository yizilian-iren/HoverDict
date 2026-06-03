import AppKit

// Entry point. With SwiftPM, top-level executable code must live in `main.swift`.
//
// We run as an `.accessory` app: no Dock icon, and — crucially for a hover/take-word
// tool — it never becomes the active application, so it won't steal focus from the
// app the user is reading (Claude / browser / VS Code).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

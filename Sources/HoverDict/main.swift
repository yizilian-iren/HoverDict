import AppKit

// Entry point. With SwiftPM, top-level executable code must live in `main.swift`.
//
// We run as an `.accessory` app: no Dock icon, and — crucially for a hover/take-word
// tool — it never becomes the active application, so it won't steal focus from the
// app the user is reading (Claude / browser / VS Code).
let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
if let demo = ProcessInfo.processInfo.environment["HOVERDICT_LOOKUP_DEMO"] {
    // Screenshots of the ⌥Z window (I-26): no hover pipeline, menu or hot keys.
    // `light` / `dark` force that appearance.
    if let name: NSAppearance.Name = ["light": .aqua, "dark": .darkAqua][demo] {
        app.appearance = NSAppearance(named: name)
    }
    DispatchQueue.main.async { delegate.showLookupDemo() }
} else {
    app.delegate = delegate
}
app.run()

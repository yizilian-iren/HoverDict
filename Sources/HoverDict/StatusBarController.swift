import AppKit

/// Menu-bar (status bar) icon with a small menu: pause/resume taking words, and quit.
/// Gives the accessory app a visible on/off affordance so the user no longer has to
/// `killall` it from the terminal.
final class StatusBarController {

    /// Called when the user toggles pause. Passes the NEW paused state (true = paused).
    var onTogglePause: ((Bool) -> Void)?
    /// Called when the user picks "Screen Recording settings…".
    var onOpenSettings: (() -> Void)?

    private let statusItem: NSStatusItem
    private let toggleItem: NSMenuItem
    private(set) var isPaused = false

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Template image adapts automatically to light/dark menu bars.
        // Fall back to a text title if the SF Symbol can't be loaded, so the item is
        // never a zero-width (invisible) button.
        if let button = statusItem.button {
            if let symbol = NSImage(systemSymbolName: "text.viewfinder",
                                    accessibilityDescription: "HoverDict") {
                symbol.isTemplate = true
                button.image = symbol
            } else {
                button.title = "📖"
            }
            button.toolTip = "HoverDict — 取词工具"
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: "HoverDict", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "暂停取词",
                                action: #selector(togglePause),
                                keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let settings = NSMenuItem(title: "屏幕录制权限设置…",
                                  action: #selector(openSettings),
                                  keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 HoverDict",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func togglePause() {
        isPaused.toggle()
        toggleItem.title = isPaused ? "继续取词" : "暂停取词"
        onTogglePause?(isPaused)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

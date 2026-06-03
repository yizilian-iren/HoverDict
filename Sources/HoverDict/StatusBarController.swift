import AppKit

/// Menu-bar (status bar) icon with: pause/resume (also bound to a global hotkey),
/// a "取词延迟" submenu, open-settings, and quit.
///
/// Pause state is OWNED by AppDelegate (single source of truth). The menu just reports
/// intent via `onTogglePause` and reflects the result via `setPaused(_:)`.
final class StatusBarController {

    /// User asked to toggle pause (from the menu). AppDelegate flips state and calls back.
    var onTogglePause: (() -> Void)?
    /// User picked a delay preset (seconds).
    var onSetDelay: ((TimeInterval) -> Void)?
    /// User picked "Screen Recording settings…".
    var onOpenSettings: (() -> Void)?

    /// Delay presets shown in the submenu.
    static let delayPresets: [(title: String, value: TimeInterval)] = [
        ("即时", 0.0),
        ("快 (0.1s)", 0.1),
        ("标准 (0.2s)", 0.2),
        ("慢 (0.4s)", 0.4),
        ("很慢 (0.8s)", 0.8),
    ]

    private let statusItem: NSStatusItem
    private let toggleItem: NSMenuItem
    private var delayItems: [NSMenuItem] = []

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

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

        // Pause/resume. Show ⇧⌘A as a hint; the actual always-on hotkey is the Carbon
        // one in HotKeyManager. (Our app is .accessory and never active, so this menu
        // key-equivalent doesn't fire on its own — it's purely for discoverability.)
        toggleItem = NSMenuItem(title: "暂停取词",
                                action: #selector(togglePause),
                                keyEquivalent: "a")
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        // Delay submenu.
        let delayParent = NSMenuItem(title: "取词延迟", action: nil, keyEquivalent: "")
        let delayMenu = NSMenu()
        for preset in Self.delayPresets {
            let item = NSMenuItem(title: preset.title,
                                  action: #selector(selectDelay(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = preset.value
            delayMenu.addItem(item)
            delayItems.append(item)
        }
        delayParent.submenu = delayMenu
        menu.addItem(delayParent)

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

    /// Reflect the current pause state in the menu title and the icon (dimmed = paused).
    func setPaused(_ paused: Bool) {
        toggleItem.title = paused ? "继续取词" : "暂停取词"
        statusItem.button?.alphaValue = paused ? 0.4 : 1.0
        statusItem.button?.toolTip = paused ? "HoverDict — 已暂停" : "HoverDict — 取词工具"
    }

    /// Tick the submenu item matching `value`.
    func markDelay(_ value: TimeInterval) {
        for item in delayItems {
            let v = (item.representedObject as? TimeInterval) ?? -1
            item.state = (abs(v - value) < 0.0001) ? .on : .off
        }
    }

    @objc private func togglePause() {
        onTogglePause?()
    }

    @objc private func selectDelay(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? TimeInterval else { return }
        onSetDelay?(value)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

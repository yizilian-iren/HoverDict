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
    /// User toggled the speak-aloud switch.
    var onToggleSound: (() -> Void)?
    /// User toggled click-to-show (vs hover) take-word mode.
    var onToggleClickMode: (() -> Void)?
    /// User toggled Japanese take-word.
    var onToggleJapanese: (() -> Void)?
    /// User picked "Screen Recording settings…".
    var onOpenSettings: (() -> Void)?
    /// User picked "自定义释义…".
    var onEditGlossary: (() -> Void)?
    /// 打字查词… (also ⌥Z anywhere).
    var onOpenLookup: (() -> Void)?
    /// Claude API key… (for the Claude translation in the lookup window).
    var onSetAPIKey: (() -> Void)?

    /// Delay presets shown in the submenu.
    static let delayPresets: [(title: String, value: TimeInterval)] = [
        ("即时", 0.0),
        ("0.01s", 0.01),
        ("快 (0.1s)", 0.1),
        ("标准 (0.2s)", 0.2),
        ("慢 (0.4s)", 0.4),
        ("很慢 (0.8s)", 0.8),
    ]

    private let statusItem: NSStatusItem
    private let toggleItem: NSMenuItem
    private let soundItem: NSMenuItem
    private let clickModeItem: NSMenuItem
    private let japaneseItem: NSMenuItem
    private var delayItems: [NSMenuItem] = []
    private var modelItems: [NSMenuItem] = []

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

        // Pause/resume. Show ⌥⇧A as a hint; the actual always-on hotkey is the Carbon
        // one in HotKeyManager. (Our app is .accessory and never active, so this menu
        // key-equivalent doesn't fire on its own — it's purely for discoverability.)
        toggleItem = NSMenuItem(title: "暂停取词",
                                action: #selector(togglePause),
                                keyEquivalent: "a")
        // Initialize before the first `self` use below (Swift requires all stored `let`s set).
        soundItem = NSMenuItem(title: "朗读发声",
                               action: #selector(toggleSound),
                               keyEquivalent: "")
        clickModeItem = NSMenuItem(title: "点击取词",
                                   action: #selector(toggleClickMode),
                                   keyEquivalent: "")
        japaneseItem = NSMenuItem(title: "日语取词",
                                  action: #selector(toggleJapanese),
                                  keyEquivalent: "")
        toggleItem.keyEquivalentModifierMask = [.option, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        let lookup = NSMenuItem(title: "打字查词（中 / 日 / 英）…",
                                action: #selector(openLookup),
                                keyEquivalent: "z")
        lookup.keyEquivalentModifierMask = [.option]
        lookup.target = self
        menu.addItem(lookup)

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

        // Click-to-show toggle (checkmark reflects state; set by setClickModeEnabled).
        clickModeItem.target = self
        menu.addItem(clickModeItem)

        // Japanese toggle (checkmark reflects state; set by setJapaneseEnabled).
        japaneseItem.target = self
        menu.addItem(japaneseItem)

        // Speak-aloud toggle (checkmark reflects state; set by setSoundEnabled).
        soundItem.target = self
        menu.addItem(soundItem)

        let glossary = NSMenuItem(title: "自定义释义…",
                                  action: #selector(editGlossary),
                                  keyEquivalent: "")
        glossary.target = self
        menu.addItem(glossary)

        let apiKey = NSMenuItem(title: "Claude API key…",
                                action: #selector(setAPIKey),
                                keyEquivalent: "")
        apiKey.target = self
        menu.addItem(apiKey)

        let modelParent = NSMenuItem(title: "Claude 模型", action: nil, keyEquivalent: "")
        let modelMenu = NSMenu()
        for model in ClaudeModel.allCases {
            let item = NSMenuItem(title: model.displayName, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = model.rawValue
            item.state = model == ClaudeModel.current ? .on : .off
            modelMenu.addItem(item)
            modelItems.append(item)
        }
        modelParent.submenu = modelMenu
        menu.addItem(modelParent)

        // 快速模式 (I-31): less thinking where the model can turn it down; on by default.
        let fast = NSMenuItem(title: "快速模式（少 thinking）", action: #selector(toggleFastMode(_:)), keyEquivalent: "")
        fast.target = self
        fast.state = ClaudeFastMode.isOn ? .on : .off
        menu.addItem(fast)

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

    /// Reflect whether speaking is on (checkmark) or off.
    func setSoundEnabled(_ enabled: Bool) {
        soundItem.state = enabled ? .on : .off
    }

    /// Reflect whether click-to-show mode is on (checkmark) or off (hover).
    func setClickModeEnabled(_ enabled: Bool) {
        clickModeItem.state = enabled ? .on : .off
    }

    /// Reflect the Japanese switch. When the 日中辞典 isn't installed the item is disabled
    /// and says how to get it.
    func setJapaneseEnabled(_ enabled: Bool, available: Bool) {
        japaneseItem.state = enabled && available ? .on : .off
        japaneseItem.isEnabled = available
        japaneseItem.title = available ? "日语取词" : "日语取词（需在「词典」App 启用日中辞典）"
    }

    /// Tick the submenu item matching `value`.
    func markDelay(_ value: TimeInterval) {
        for item in delayItems {
            let v = (item.representedObject as? TimeInterval) ?? -1
            item.state = (abs(v - value) < 0.0001) ? .on : .off
        }
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let model = ClaudeModel(rawValue: raw) else { return }
        ClaudeModel.current = model
        for item in modelItems { item.state = item === sender ? .on : .off }
    }

    @objc private func toggleFastMode(_ sender: NSMenuItem) {
        ClaudeFastMode.isOn.toggle()
        sender.state = ClaudeFastMode.isOn ? .on : .off
    }

    @objc private func togglePause() {
        onTogglePause?()
    }

    @objc private func toggleSound() {
        onToggleSound?()
    }

    @objc private func toggleClickMode() {
        onToggleClickMode?()
    }

    @objc private func toggleJapanese() {
        onToggleJapanese?()
    }

    @objc private func selectDelay(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? TimeInterval else { return }
        onSetDelay?(value)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func setAPIKey() {
        onSetAPIKey?()
    }

    @objc private func openLookup() {
        onOpenLookup?()
    }

    @objc private func editGlossary() {
        onEditGlossary?()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

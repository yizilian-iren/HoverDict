import AppKit
import Carbon

/// Wires the pipeline together:
///   MouseMonitor (cursor still / click) → ScreenCapturer → OCRService → CoordinateMapper
///   → hit test → OverlayPanel.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let mouseMonitor = MouseMonitor(stillInterval: 0.2)
    private let capturer = ScreenCapturer()
    private let ocr = OCRService()
    private let panel = OverlayPanel()
    private let shiftWatcher = ShiftWatcher()
    private var statusBar: StatusBarController?
    private let hotKey = HotKeyManager()
    /// ⌥Z opens the typed-lookup window.
    private let lookupHotKey = HotKeyManager()
    private lazy var lookupWindow: LookupWindow = {
        let window = LookupWindow()
        window.dictionaryText = { [weak self] query, language in
            self?.typedDictionaryText(query, language: language)
        }
        window.soundEnabled = { [weak self] in self?.panel.soundEnabled ?? true }
        window.history = history
        return window
    }()
    /// ⌥Z lookups and clicked words (I-29). The demo keeps its own in memory.
    private lazy var history = LookupHistory()

    /// Single source of truth for pause state.
    private var isPaused = false
    /// When true, translation/TTS only appear after a left click (not hover).
    private var clickModeEnabled = false
    /// UserDefaults key for the persisted take-word delay.
    private let delayKey = "HoverDict.stillInterval"
    /// UserDefaults key for the persisted speak-aloud switch.
    private let soundKey = "HoverDict.soundEnabled"
    /// UserDefaults key for the persisted click-to-show switch.
    private let clickModeKey = "HoverDict.clickToShow"
    /// When true, text the English pass can't define is re-read as Japanese.
    private var japaneseEnabled = true
    /// UserDefaults key for the persisted Japanese switch.
    private let japaneseKey = "HoverDict.japanese"

    private let dictionary: DictionaryService? = {
        // Bundled ECDICT database (copied into Contents/Resources by build_app.sh).
        if let path = Bundle.main.url(forResource: "ecdict", withExtension: "db")?.path {
            return DictionaryService(databasePath: path)
        }
        NSLog("HoverDict: ecdict.db not found in bundle — definitions disabled.")
        return nil
    }()

    /// Bundled tech glossary (thread → 线程；线), tried before the dictionaries.
    private let techGlossary: Glossary? = Bundle.main
        .url(forResource: "tech_glossary", withExtension: "txt")
        .map { Glossary(contentsOf: $0) }

    /// The user's own `word = 释义` list (menu 自定义释义…); wins over everything.
    private let userGlossary = UserGlossary()

    /// macOS's built-in 牛津英汉词典, tried before ECDICT; nil when it isn't installed
    /// (English then uses ECDICT alone).
    private let oxfordDictionary = OxfordDictionary()

    /// macOS's built-in 日中辞典; nil when it isn't installed (Japanese then stays off).
    private let japaneseDictionary = JapaneseDictionary()

    // Guards against overlapping capture/OCR passes if the cursor keeps settling.
    private var isProcessing = false
    /// Bumped on mouse-move dismiss so an in-flight OCR result won't re-show the panel.
    private var lookupGeneration = 0
    /// Click mode: where the last take-word click happened. Movement within
    /// `clickDismissRadius` of it (hand jitter after clicking) keeps the popup open.
    private var clickAnchor: CGPoint?
    /// The English popup on screen, so Shift can expand it to the full entry and back.
    private struct EnglishPopup {
        let word: String
        let cursor: CGPoint
        let glossary: String?
        let generation: Int
        let showShort: (_ speak: Bool) -> Void
        var expanded = false
    }
    private var englishPopup: EnglishPopup?
    private let clickDismissRadius: CGFloat = 12

    /// `HOVERDICT_LOOKUP_DEMO=1` (main.swift): only the ⌥Z window with canned results.
    /// `list`: the empty window with a made-up history instead; `streaming`: Claude's answer
    /// half-written.
    func showLookupDemo(fallback: Bool, list: Bool, streaming: Bool = false) {
        history = LookupHistory(directory: nil)
        if list {
            lookupWindow.showListDemo()
        } else {
            lookupWindow.showDemo(dictionary: typedDictionaryText("lora", language: .en), fallback: fallback,
                                  streaming: streaming)
        }
    }

    /// Click mode: the clicked word and what the popup shows go on file (not in the ⌥Z list).
    private func recordClick(_ word: String, language: TypedLanguage) {
        let app = NSWorkspace.shared.frontmostApplication
        history.append(HistoryRecord(query: word, language: language.rawValue, date: Date(), source: .click,
                                     appName: app?.localizedName, bundleID: app?.bundleIdentifier,
                                     dictionaryRTF: HistoryRecord.rtf(panel.shownText)))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.installEditMenu()
        // Always set up the menu-bar control and the monitor FIRST, unconditionally.
        // This way the app never silently dies on a missing permission, and the user
        // always has a visible icon to pause/quit/open settings. Without permission the
        // capture step simply returns nil (no popup) until permission is granted.
        startPipeline()

        // Then nudge for permission if needed — non-blocking, never terminates.
        promptForPermissionIfNeeded()
    }

    /// A menu-bar-only app has no main menu, so ⌘V/⌘C/⌘X/⌘A/⌘Z never reach text fields.
    /// Install an Edit menu (invisible while we're .accessory) that routes them down the responder chain.
    private static func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // MARK: - Permission

    /// If Screen Recording isn't granted yet, trigger the system prompt and show
    /// guidance. Does NOT terminate — the menu-bar icon stays available and the app
    /// keeps running, so granting + reopening (or just regranting) is smooth.
    private func promptForPermissionIfNeeded() {
        guard !PermissionManager.hasScreenRecordingPermission() else { return }

        // First call triggers the system prompt + registers us in the Settings list.
        PermissionManager.requestScreenRecordingPermission()

        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        HoverDict 通过屏幕 OCR 取词,需要「屏幕录制」权限。

        请在 系统设置 → 隐私与安全性 → 屏幕录制 中勾选 HoverDict,
        然后退出并重新启动本应用(授权后必须重启进程才生效)。

        提示:菜单栏图标里也能随时打开此设置或退出。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            PermissionManager.openScreenRecordingSettings()
        }
        // No terminate — keep running with the menu-bar icon available.
    }

    // MARK: - Pipeline

    private func startPipeline() {
        // Restore the saved take-word delay (default 0.2s).
        let savedDelay = UserDefaults.standard.object(forKey: delayKey) as? TimeInterval ?? 0.2
        mouseMonitor.stillInterval = savedDelay

        mouseMonitor.onCursorStill = { [weak self] cursorGlobal in
            guard let self, !self.clickModeEnabled else { return }
            self.handleLookup(at: cursorGlobal, fromClick: false)
        }
        mouseMonitor.onClick = { [weak self] cursorGlobal in
            guard let self, self.clickModeEnabled else { return }
            self.clickAnchor = cursorGlobal
            self.handleLookup(at: cursorGlobal, fromClick: true)
        }
        // Cursor movement fades the popup out (hover mode: any movement — hide
        // immediately, then re-show after stillness; click mode: only once the cursor
        // leaves `clickDismissRadius` around the click).
        mouseMonitor.onMouseMoved = { [weak self] point in
            self?.dismissPanelForMouseMove(at: point)
        }
        mouseMonitor.start()

        // A wedged OCR pass would leave `isProcessing` set and every later lookup dropped:
        // start afresh instead.
        ocr.onStuck = {
            Self.relaunch()
        }

        shiftWatcher.isActive = { [weak self] in
            guard let self, let popup = self.englishPopup else { return false }
            return self.panel.isVisible && popup.generation == self.lookupGeneration
        }
        shiftWatcher.onPress = { [weak self] in
            self?.toggleDetail()
        }

        // Menu-bar icon: pause/resume, delay presets, settings, quit.
        let bar = StatusBarController()
        bar.onTogglePause = { [weak self] in
            guard let self else { return }
            self.setPaused(!self.isPaused)
        }
        bar.onSetDelay = { [weak self] delay in
            self?.setDelay(delay)
        }
        bar.onToggleSound = { [weak self] in
            guard let self else { return }
            self.setSoundEnabled(!self.panel.soundEnabled)
        }
        bar.onToggleClickMode = { [weak self] in
            guard let self else { return }
            self.setClickModeEnabled(!self.clickModeEnabled)
        }
        bar.onToggleJapanese = { [weak self] in
            guard let self else { return }
            self.setJapaneseEnabled(!self.japaneseEnabled)
        }
        bar.onOpenSettings = {
            PermissionManager.openScreenRecordingSettings()
        }
        bar.onEditGlossary = { [weak self] in
            guard let self else { return }
            self.userGlossary.ensureExists()
            NSWorkspace.shared.open(self.userGlossary.url)
        }
        bar.onOpenLookup = { [weak self] in
            self?.lookupWindow.toggle()
        }
        bar.onSetAPIKey = {
            Self.askForAPIKey()
        }
        bar.markDelay(savedDelay)
        bar.setPaused(false)

        // Restore the saved speak-aloud switch (default on).
        let savedSound = UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
        panel.soundEnabled = savedSound
        bar.setSoundEnabled(savedSound)

        // Restore the saved click-to-show switch (default off = hover).
        let savedClickMode = UserDefaults.standard.object(forKey: clickModeKey) as? Bool ?? false
        clickModeEnabled = savedClickMode
        bar.setClickModeEnabled(savedClickMode)

        // Restore the saved Japanese switch (default on).
        japaneseEnabled = UserDefaults.standard.object(forKey: japaneseKey) as? Bool ?? true
        bar.setJapaneseEnabled(japaneseEnabled, available: japaneseDictionary != nil)
        warmUpJapaneseIfNeeded()

        statusBar = bar

        // Global hotkey ⌥⇧A toggles take-word on/off (no Accessibility permission needed).
        hotKey.onTrigger = { [weak self] in
            guard let self else { return }
            self.setPaused(!self.isPaused)
        }
        hotKey.register()
        lookupHotKey.onTrigger = { [weak self] in
            self?.lookupWindow.toggle()
        }
        lookupHotKey.register(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey), id: 2)

        NSLog("HoverDict: running. Hover (or click, if enabled) over English or Japanese text to take a word. (⌥⇧A toggles)")
    }

    /// Pause/resume take-word. Drives the monitor, the panel, and the menu-bar UI.
    private func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            mouseMonitor.stop()
            lookupGeneration += 1
            panel.hidePanel(animated: false)
        } else {
            mouseMonitor.start()
        }
        statusBar?.setPaused(paused)
    }

    /// Fade-dismiss on cursor movement; also invalidates any in-flight lookup.
    private func dismissPanelForMouseMove(at point: CGPoint) {
        guard panel.isVisible || isProcessing else { return }
        if clickModeEnabled, let anchor = clickAnchor,
           hypot(point.x - anchor.x, point.y - anchor.y) <= clickDismissRadius {
            return
        }
        clickAnchor = nil
        lookupGeneration += 1
        if panel.isVisible {
            panel.hidePanel(animated: true)
        }
    }

    /// Change and persist the take-word debounce delay.
    private func setDelay(_ delay: TimeInterval) {
        mouseMonitor.stillInterval = delay
        UserDefaults.standard.set(delay, forKey: delayKey)
        statusBar?.markDelay(delay)
    }

    /// Toggle and persist whether words are spoken aloud.
    private func setSoundEnabled(_ enabled: Bool) {
        panel.soundEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: soundKey)
        statusBar?.setSoundEnabled(enabled)
    }

    /// Toggle and persist click-to-show mode (on = click; off = hover).
    private func setClickModeEnabled(_ enabled: Bool) {
        clickModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: clickModeKey)
        statusBar?.setClickModeEnabled(enabled)
        // Switching modes: dismiss any lingering popup so state stays clear.
        lookupGeneration += 1
        panel.hidePanel(animated: false)
    }

    /// Toggle and persist Japanese take-word.
    private func setJapaneseEnabled(_ enabled: Bool) {
        japaneseEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: japaneseKey)
        statusBar?.setJapaneseEnabled(enabled, available: japaneseDictionary != nil)
        warmUpJapaneseIfNeeded()
    }

    private func warmUpJapaneseIfNeeded() {
        guard japaneseEnabled, japaneseDictionary != nil else { return }
        DispatchQueue.global(qos: .utility).async { [ocr] in
            ocr.warmUpJapanese()
        }
    }

    /// Shared capture → OCR → hit-test → show/hide path for hover and click.
    ///
    /// Two OCR passes, because Vision only really uses the FIRST recognition language:
    /// ["en-US"] alone is fastest and most accurate for English, while ["ja-JP", …] is the
    /// only way to read kana. So English runs first; only when it yields no definition
    /// (Japanese / Chinese text, noise) is the same image re-read as Japanese.
    /// `fromClick` makes the panel speak immediately (and re-speak on another click).
    private func handleLookup(at cursorGlobal: CGPoint, fromClick: Bool) {
        // Moving onto / clicking the popup dismisses it (the panel ignores the mouse).
        if panel.isVisible && panel.frame.contains(cursorGlobal) {
            lookupGeneration += 1
            panel.hidePanel(animated: true)
            return
        }
        guard !isProcessing else { return }
        isProcessing = true
        let generation = lookupGeneration
        let japaneseDictionary = japaneseEnabled ? self.japaneseDictionary : nil

        Task { [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }

            guard let capture = await self.capturer.capture(around: cursorGlobal) else {
                await MainActor.run {
                    guard generation == self.lookupGeneration else { return }
                    self.panel.hidePanel(animated: true)
                }
                return
            }

            let words = self.ocr.recognize(in: capture.cgImage, includeJapanese: false).words
            let hits = CoordinateMapper.resolve(words: words,
                                                captureRectGlobal: capture.captureRectGlobal)
            let rawHit = CoordinateMapper.wordUnderCursor(hits, cursorGlobal: cursorGlobal)
            // Skip numbers and isolated UI labels (buttons / toolbar items) so clicking
            // "Send" or hovering "123" doesn't pop a translation.
            let hit: WordHit?
            if let rawHit, LookupFilter.shouldSkip(rawHit, in: hits, fromClick: fromClick) {
                hit = nil
            } else {
                hit = rawHit
            }

            // Look up off the main thread; use OCR neighbors to prefer a matching POS sense.
            // The user's glossary, then the tech glossary; then Oxford (better
            // definitions); ECDICT for what it doesn't have.
            let glossaryText: String?
            let oxfordSenses: [OxfordSense]?
            let entry: DictionaryEntry?
            let preferredPOS: SensePicker.POSKind?
            if let hit,
               let text = self.userGlossary.lookup(hit.text) ?? self.techGlossary?.lookup(hit.text) {
                glossaryText = text
                preferredPOS = nil
                oxfordSenses = nil
                entry = nil
            } else if let hit {
                glossaryText = nil
                let phrase = CoordinateMapper.contextPhrase(around: hit, in: hits)
                preferredPOS = SensePicker.lexicalPOS(of: hit.text, in: phrase)
                if OxfordDictionary.prefersECDICT(hit.text),
                   let acronym = self.dictionary?.lookup(hit.text) {
                    oxfordSenses = nil
                    entry = acronym
                } else {
                    oxfordSenses = self.oxfordDictionary?.lookup(hit.text, preferredPOS: preferredPOS)
                    entry = oxfordSenses == nil ? self.dictionary?.lookup(hit.text) : nil
                }
            } else {
                glossaryText = nil
                preferredPOS = nil
                oxfordSenses = nil
                entry = nil
            }

            // English found nothing to define → re-read as Japanese. `onJapanese` means the
            // cursor is on a kana line: then show the Japanese result or nothing (a particle
            // like は), never the English "not found" for OCR noise.
            let onJapanese: Bool
            let japaneseEntry: JapaneseEntry?
            if glossaryText == nil, oxfordSenses == nil, entry == nil, let japaneseDictionary,
               let target = CoordinateMapper.japaneseTarget(
                   in: self.ocr.recognize(in: capture.cgImage, includeJapanese: true).lines,
                   captureRectGlobal: capture.captureRectGlobal,
                   cursorGlobal: cursorGlobal) {
                onJapanese = true
                japaneseEntry = japaneseDictionary.lookup(line: target.line,
                                                          utf16Offset: target.utf16Offset)
            } else {
                onJapanese = false
                japaneseEntry = nil
            }

            await MainActor.run {
                // Cursor moved (or mode changed) while we were working — drop the result.
                guard generation == self.lookupGeneration else { return }
                if onJapanese {
                    if let japaneseEntry {
                        self.panel.showJapanese(japaneseEntry,
                                                forceSpeak: fromClick,
                                                below: cursorGlobal)
                        if fromClick { self.recordClick(japaneseEntry.headword, language: .ja) }
                    } else {
                        self.panel.hidePanel(animated: true)
                    }
                } else if let hit {
                    // forceSpeak only on this first show; re-showing after Shift stays quiet.
                    let showShort: (Bool) -> Void
                    if let glossaryText {
                        showShort = { speak in
                            self.panel.show(word: hit.text, text: glossaryText,
                                            forceSpeak: speak, below: cursorGlobal)
                        }
                    } else if let oxfordSenses {
                        showShort = { speak in
                            self.panel.show(word: hit.text, senses: oxfordSenses,
                                            forceSpeak: speak, below: cursorGlobal)
                        }
                    } else {
                        showShort = { speak in
                            self.panel.show(word: hit.text, entry: entry, preferredPOS: preferredPOS,
                                            forceSpeak: speak, below: cursorGlobal)
                        }
                    }
                    showShort(fromClick)
                    if fromClick { self.recordClick(hit.text, language: .en) }
                    self.englishPopup = EnglishPopup(word: hit.text,
                                                     cursor: cursorGlobal,
                                                     glossary: glossaryText,
                                                     generation: generation,
                                                     showShort: showShort)
                    self.shiftWatcher.start()
                } else {
                    // Strict mode: nothing directly under the cursor → hide the panel.
                    self.panel.hidePanel(animated: true)
                }
            }
        }
    }

    /// Shift on an English popup: swap between the one-liner and the full entry.
    private func toggleDetail() {
        guard var popup = englishPopup, popup.generation == lookupGeneration else { return }
        if popup.expanded {
            popup.expanded = false
            englishPopup = popup
            popup.showShort(false)
            return
        }
        let generation = lookupGeneration
        let word = popup.word, glossary = popup.glossary, cursor = popup.cursor
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let groups = self.oxfordDictionary?.detail(word)
            let ecdict = self.dictionary?.lookup(word)?.translation
            await MainActor.run {
                guard generation == self.lookupGeneration, self.panel.isVisible,
                      self.englishPopup?.generation == generation else { return }
                self.englishPopup?.expanded = true
                let text = OverlayPanel.detailText(glossary: glossary, groups: groups, ecdict: ecdict)
                self.panel.showDetail(word: word, text: text, below: cursor)
            }
        }
    }

    /// The 词典 block of the typed-lookup window: for English the glossaries, Oxford and
    /// ECDICT as in the Shift-expanded popup (glossary first); for Japanese the 日中辞典;
    /// for Chinese the tech glossary read backwards (线程 → thread). Off the main thread.
    private func typedDictionaryText(_ query: String, language: TypedLanguage) -> NSAttributedString? {
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ]
        switch language {
        case .en:
            let glossary = userGlossary.lookup(query) ?? techGlossary?.lookup(query)
            let groups = oxfordDictionary?.detail(query)
            let ecdict = dictionary?.lookup(query)
            guard glossary != nil || groups != nil || ecdict?.translation != nil else { return nil }
            let text = NSMutableAttributedString()
            if let phonetic = ecdict?.phonetic {
                text.append(NSAttributedString(string: "/\(phonetic)/\n", attributes: dim))
            }
            text.append(OverlayPanel.detailText(glossary: glossary, groups: groups,
                                                ecdict: ecdict?.translation))
            return text
        case .ja:
            guard let entry = japaneseDictionary?.lookup(line: query, utf16Offset: 0) else { return nil }
            let text = NSMutableAttributedString(string: entry.headword, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
            if let reading = entry.reading {
                text.append(NSAttributedString(string: "  " + reading, attributes: dim))
            }
            for sense in entry.senses {
                text.append(NSAttributedString(string: "\n" + sense, attributes: body))
            }
            return text
        case .zh:
            let keys = techGlossary?.reverseLookup(query) ?? []
            guard !keys.isEmpty else { return nil }
            let text = NSMutableAttributedString(string: "词表  ", attributes: dim)
            let lines = keys.prefix(5).map { key in
                "\(key)（\(techGlossary?.lookup(key) ?? "")）"
            }
            text.append(NSAttributedString(string: lines.joined(separator: "\n"), attributes: body))
            return text
        }
    }

    /// Menu Claude API key…: paste the key from console.anthropic.com; it goes to the Keychain.
    private static func askForAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = APIKeyStore.read() == nil
            ? "打字查词（⌥Z）用它让 Claude 翻译。在 console.anthropic.com → API Keys 新建一个，粘贴到这里；存进 Keychain。"
            : "已经存了一个 key。粘贴新的会替换它；清空再按 Save 会删掉它。"
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        input.placeholderString = "sk-ant-…"
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !APIKeyStore.save(input.stringValue) {
            let failed = NSAlert()
            failed.messageText = "没存进 Keychain"
            failed.runModal()
        }
    }

    /// UserDefaults key for the times of recent stuck-OCR relaunches (see `RelaunchGuard`).
    private static let relaunchHistoryKey = "HoverDict.relaunchHistory"
    private static var shownStuckNotice = false

    /// Quit and open this .app again a moment later (once the hot key is released).
    private static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            NSLog("HoverDict: not running from an .app; can't relaunch")
            return
        }
        let defaults = UserDefaults.standard
        let history = (defaults.array(forKey: relaunchHistoryKey) as? [Double] ?? [])
            .map(Date.init(timeIntervalSince1970:))
        guard let updated = RelaunchGuard.allow(history: history, now: Date()) else {
            NSLog("HoverDict: OCR stuck again right after relaunching; not relaunching")
            showStuckNotice()
            return
        }
        defaults.set(updated.map(\.timeIntervalSince1970), forKey: relaunchHistoryKey)
        NSLog("HoverDict: relaunching")
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/sh")
        opener.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        do {
            try opener.run()
        } catch {
            NSLog("HoverDict: relaunch failed: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    private static func showStuckNotice() {
        guard !shownStuckNotice else { return }
        shownStuckNotice = true
        let alert = NSAlert()
        alert.messageText = "HoverDict 的 OCR 卡住了"
        alert.informativeText = """
        自动重启了 \(RelaunchGuard.maxRelaunches) 次也没好,取词先停了。
        请从菜单栏退出 HoverDict 再打开;还是不行就重启一下 Mac。
        """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mouseMonitor.stop()
        hotKey.unregister()
        lookupHotKey.unregister()
        ClaudeVoice.shared.shutdown()
    }
}

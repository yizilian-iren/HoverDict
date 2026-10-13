import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always set up the menu-bar control and the monitor FIRST, unconditionally.
        // This way the app never silently dies on a missing permission, and the user
        // always has a visible icon to pause/quit/open settings. Without permission the
        // capture step simply returns nil (no popup) until permission is granted.
        startPipeline()

        // Then nudge for permission if needed — non-blocking, never terminates.
        promptForPermissionIfNeeded()
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

    func applicationWillTerminate(_ notification: Notification) {
        mouseMonitor.stop()
        hotKey.unregister()
    }
}

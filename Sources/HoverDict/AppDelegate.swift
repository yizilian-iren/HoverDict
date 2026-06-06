import AppKit

/// Wires the pipeline together:
///   MouseMonitor (cursor still) → ScreenCapturer → OCRService → CoordinateMapper
///   → hit test → OverlayPanel.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let mouseMonitor = MouseMonitor(stillInterval: 0.2)
    private let capturer = ScreenCapturer()
    private let ocr = OCRService()
    private let panel = OverlayPanel()
    private var statusBar: StatusBarController?
    private let hotKey = HotKeyManager()

    /// Single source of truth for pause state.
    private var isPaused = false
    /// UserDefaults key for the persisted take-word delay.
    private let delayKey = "HoverDict.stillInterval"

    private let dictionary: DictionaryService? = {
        // Bundled ECDICT database (copied into Contents/Resources by build_app.sh).
        if let path = Bundle.main.url(forResource: "ecdict", withExtension: "db")?.path {
            return DictionaryService(databasePath: path)
        }
        NSLog("HoverDict: ecdict.db not found in bundle — definitions disabled.")
        return nil
    }()

    // Guards against overlapping capture/OCR passes if the cursor keeps settling.
    private var isProcessing = false

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
            self?.handleCursorStill(at: cursorGlobal)
        }
        mouseMonitor.start()

        // Menu-bar icon: pause/resume, delay presets, settings, quit.
        let bar = StatusBarController()
        bar.onTogglePause = { [weak self] in
            guard let self else { return }
            self.setPaused(!self.isPaused)
        }
        bar.onSetDelay = { [weak self] delay in
            self?.setDelay(delay)
        }
        bar.onOpenSettings = {
            PermissionManager.openScreenRecordingSettings()
        }
        bar.markDelay(savedDelay)
        bar.setPaused(false)
        statusBar = bar

        // Global hotkey ⌘⇧A toggles take-word on/off (no Accessibility permission needed).
        hotKey.onTrigger = { [weak self] in
            guard let self else { return }
            self.setPaused(!self.isPaused)
        }
        hotKey.register()

        NSLog("HoverDict: running. Hover over English text to take a word. (⌘⇧A toggles)")
    }

    /// Pause/resume take-word. Drives the monitor, the panel, and the menu-bar UI.
    private func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            mouseMonitor.stop()
            panel.hidePanel()
        } else {
            mouseMonitor.start()
        }
        statusBar?.setPaused(paused)
    }

    /// Change and persist the take-word debounce delay.
    private func setDelay(_ delay: TimeInterval) {
        mouseMonitor.stillInterval = delay
        UserDefaults.standard.set(delay, forKey: delayKey)
        statusBar?.markDelay(delay)
    }

    private func handleCursorStill(at cursorGlobal: CGPoint) {
        // Moving onto the popup dismisses it (the panel itself ignores the mouse).
        if panel.isVisible && panel.frame.contains(cursorGlobal) {
            panel.hidePanel()
            return
        }
        guard !isProcessing else { return }
        isProcessing = true

        Task { [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }

            guard let capture = await self.capturer.capture(around: cursorGlobal) else {
                await MainActor.run { self.panel.hidePanel() }
                return
            }

            let words = self.ocr.recognizeWords(in: capture.cgImage)
            let hits = CoordinateMapper.resolve(words: words,
                                                captureRectGlobal: capture.captureRectGlobal)
            let hit = CoordinateMapper.wordUnderCursor(hits, cursorGlobal: cursorGlobal)

            // Look up the definition off the main thread (DictionaryService is synchronous).
            let entry = hit.flatMap { self.dictionary?.lookup($0.text) }

            await MainActor.run {
                if let hit {
                    self.panel.show(word: hit.text, entry: entry, below: cursorGlobal)
                } else {
                    // Strict mode: nothing directly under the cursor → hide the panel.
                    self.panel.hidePanel()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mouseMonitor.stop()
        hotKey.unregister()
    }
}

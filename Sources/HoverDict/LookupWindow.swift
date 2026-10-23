import AppKit
import AVFoundation
import Translation

/// The typed-lookup window (⌥Z): type a word or term in 中 / 日 / 英, press Return, and
/// get two cards (D-014) — the dictionaries HoverDict already has (only when they have the
/// word), and Claude's translation with every main sense. When Claude gives nothing (no key,
/// offline, an error), macOS's offline translation into the other two languages takes its
/// place. Every name has a speaker that reads it in the user's Claude voice.
///
/// Looks like Agent Deck (N-006, I-26, I-27): a borderless sheet of frosted glass with Deck's
/// tint, 14 px corners, the input bare on top, results as 10 px cards 8 px apart and 8 px in
/// from the edge — no title bar, separator lines or colored edges. Names in the text color,
/// labels and explanations in Deck's dimmer ones, nothing bold; mauve only on the speakers
/// and the model's name.
final class LookupWindow: NSPanel, NSTextFieldDelegate, NSTextViewDelegate {

    /// The dictionary block for a query (call off the main thread); nil = nothing found.
    var dictionaryText: ((String, TypedLanguage) -> NSAttributedString?)?
    /// Whether to read the query aloud when it's looked up (menu 朗读发声).
    var soundEnabled: () -> Bool = { true }
    /// Where lookups are recorded, and what the empty window lists (I-29).
    var history: LookupHistory?

    private let width: CGFloat = 560
    private let inputHeight: CGFloat = 48
    private let maxHeight: CGFloat = 620

    private let field = NSTextField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let synthesizer = AVSpeechSynthesizer()
    private var starButton: NSButton!
    private var refreshButton: NSButton!

    /// The rows of the history list (favorites, then recent), and the one ↑↓ is on.
    private var listRows: [HistoryRowView] = []
    private var selectedRow: Int?
    /// The app in front before ⌥Z brought the window up, recorded with each lookup.
    private var previousApp: NSRunningApplication?

    /// Bumped per query, so a slow answer for an earlier one is dropped.
    private var generation = 0
    private var state: State?
    /// The demo stays up when another app takes focus, so it can be screenshotted.
    private var isDemo = false

    private enum Pending<T> {
        case loading
        case done(T)
    }

    private struct State {
        var query: String
        var language: TypedLanguage
        var dictionary: Pending<NSAttributedString?> = .loading
        var claude: Pending<Result<ClaudeTranslation, ClaudeTranslator.Failure>> = .loading
        /// What Claude has written so far, shown while it's still loading.
        var claudePartial: ClaudeTranslation?
        /// Opened from the history: shows 重新查.
        var stored = false
        /// macOS's translation, asked for only once Claude has failed.
        var translations: [TypedLanguage: Pending<String>] = [:]
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 54),
                   styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        buildContent()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func buildContent() {
        // Deck's Glass: macOS's frosted material (the user's Deck uses Full screen) with
        // Deck's Warm base over it. The corners are a mask image (Apple's way for this
        // view) rather than a layer mask.
        let glass = NSVisualEffectView()
        glass.material = .fullScreenUI
        glass.blendingMode = .behindWindow
        // Stays glass when HoverDict isn't the front app (Deck's "glass always").
        glass.state = .active
        glass.maskImage = Self.roundedMask(radius: DeckTheme.sheetRadius)

        let tint = TintView(color: DeckTheme.glassBackground, radius: DeckTheme.sheetRadius)
        tint.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(tint)

        let icon = NSImageView(image: Self.symbol("magnifyingglass", size: 14, weight: .regular))
        icon.contentTintColor = DeckTheme.text3
        icon.translatesAutoresizingMaskIntoConstraints = false

        let inputFont = NSFont.systemFont(ofSize: 16)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = inputFont
        field.textColor = DeckTheme.text
        field.placeholderAttributedString = NSAttributedString(
            string: "中文、日本語、English",
            attributes: [.font: inputFont, .foregroundColor: DeckTheme.text3])
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false

        let speak = Self.button("speaker.wave.2", tip: "朗读", target: self, action: #selector(speakQuery))
        speak.contentTintColor = DeckTheme.accent
        refreshButton = Self.button("arrow.clockwise", tip: "重新查", target: self, action: #selector(refresh))
        refreshButton.contentTintColor = DeckTheme.text3
        starButton = Self.button("star", tip: "收藏", target: self, action: #selector(toggleFavorite))
        let buttons = NSStackView(views: [refreshButton, starButton, speak])
        buttons.orientation = .horizontal
        buttons.spacing = 4
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let gap = DeckTheme.gap
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: gap, bottom: gap, right: gap)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [icon, field, buttons, scroll] as [NSView] { glass.addSubview(view) }
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: glass.topAnchor),
            tint.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: glass.trailingAnchor),

            // The icon sits over the cards' text column (gap + card padding).
            icon.centerXAnchor.constraint(equalTo: glass.leadingAnchor, constant: gap + CardView.padding + 7),
            icon.centerYAnchor.constraint(equalTo: glass.topAnchor, constant: inputHeight / 2),
            field.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: gap + CardView.padding + 22),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: gap),
            buttons.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -(gap + CardView.padding - 4)),
            buttons.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: glass.topAnchor, constant: inputHeight),
            scroll.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: glass.bottomAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        contentView = glass
    }

    private static func button(_ symbol: String, tip: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(image: Self.symbol(symbol, size: 13, weight: .regular), target: target, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    /// A stretchable rounded rectangle for `NSVisualEffectView.maskImage`.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Show / hide

    /// ⌥Z: bring the window up empty, with the history list (I-28: the last result doesn't
    /// stay), or put it away when it's already in front.
    func toggle() {
        if isVisible && isKeyWindow {
            close()
            return
        }
        if !isVisible {
            previousApp = NSWorkspace.shared.frontmostApplication
            if !isDemo { ClaudeTranslator.preconnect() }
            generation += 1
            state = nil
            field.stringValue = ""
            selectedRow = nil
            render()
            placeOnMouseScreen()
        }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        // The selection in mauve like the cards', not the system's blue.
        (field.currentEditor() as? NSTextView)?.selectedTextAttributes =
            [.backgroundColor: DeckTheme.accent.withAlphaComponent(0.2)]
        field.currentEditor()?.selectAll(nil)
    }

    /// Clicking anywhere else puts it away, like Deck's Finder and Spotlight.
    override func resignKey() {
        super.resignKey()
        if isVisible && !isDemo { close() }
    }

    override func close() {
        ClaudeVoice.shared.stop()
        super.close()
    }

    private func placeOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        // The top edge stays put as results grow the window downward.
        setFrame(NSRect(x: area.midX - width / 2, y: area.minY + area.height * 0.72 - frame.height,
                        width: width, height: frame.height), display: false)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        case #selector(NSResponder.moveDown(_:)) where !listRows.isEmpty:
            select(selectedRow.map { min($0 + 1, listRows.count - 1) } ?? 0)
            return true
        case #selector(NSResponder.moveUp(_:)) where !listRows.isEmpty:
            select(selectedRow.map { max($0 - 1, 0) } ?? listRows.count - 1)
            return true
        default:
            return false
        }
    }

    /// Emptying the field brings the list back; typing puts it away.
    func controlTextDidChange(_ obj: Notification) {
        if field.stringValue.isEmpty {
            if state != nil {
                generation += 1
                state = nil
            }
            selectedRow = nil
            render()
        } else if state == nil && !listRows.isEmpty {
            render()
        }
    }

    /// `HOVERDICT_LOOKUP_DEMO=1`: the window with canned results for 「lora」 (what the user
    /// screenshotted for I-26), no network or speech — to check the look. `fallback`: Claude
    /// failed (no key) and the system translation stands in. `streaming`: Claude's answer
    /// as it shows while still being written (I-30).
    func showDemo(dictionary: NSAttributedString?, fallback: Bool, streaming: Bool = false) {
        isDemo = true
        toggle()
        field.stringValue = "lora"
        var demo = State(query: "lora", language: .en)
        demo.dictionary = .done(dictionary)
        if fallback {
            demo.claude = .done(.failure(.noKey))
            demo.translations = [.zh: .done("劳拉"), .ja: .done("ローラ")]
        } else if streaming {
            demo.claudePartial = PartialJSON.translation(
                #"{"zh":"LoRA（低秩适配，一种大模型微调方法）；LoRa（远距离低功耗无线通信技术）；洛拉（人名）","ja":"LoRA（低ランク適応）；LoRa（長"#,
                model: .current)
        } else {
            demo.claude = .done(.success(ClaudeTranslation(
                zh: "LoRA（低秩适配，一种大模型微调方法）；LoRa（远距离低功耗无线通信技术）；洛拉（人名）",
                ja: "LoRA（低ランク適応）；LoRa（長距離無線通信規格）；ローラ（人名）",
                en: "LoRA (Low-Rank Adaptation); LoRa (long-range radio); Lora (given name)",
                note: "LoRA 是一种只训练少量低秩矩阵来微调大模型的方法，省显存、可插拔。", seconds: 1.8)))
        }
        state = demo
        render()
    }

    /// `HOVERDICT_LOOKUP_DEMO=list`: the empty window over a made-up history.
    func showListDemo() {
        isDemo = true
        let words: [(String, TypedLanguage, String, String, String)] = [
            ("transformer", .en, "Transformer（神经网络架构）；变压器", "トランスフォーマー", "Transformer"),
            ("lora", .en, "LoRA（低秩适配）；LoRa（远距离无线）", "LoRA", "LoRA"),
            ("推論", .ja, "推理（模型推断）", "推論", "inference"),
            ("线程", .zh, "线程", "スレッド", "thread（执行单元）"),
            ("embedding", .en, "嵌入（向量表示）", "埋め込み", "embedding"),
        ]
        for (i, word) in words.enumerated() {
            history?.append(HistoryRecord(
                query: word.0, language: word.1.rawValue, date: Date(timeIntervalSinceNow: Double(i - 10) * 60),
                source: .typed,
                claude: StoredTranslation(ClaudeTranslation(zh: word.2, ja: word.3, en: word.4, note: ""))))
        }
        history?.setFavorite(true, for: "lora")
        toggle()
        select(1)
    }

    // MARK: - Lookup

    /// Return: look the field up — or, on the empty field, open the list row ↑↓ is on.
    @objc private func submit() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            if let selectedRow, listRows.indices.contains(selectedRow) { open(listRows[selectedRow].record) }
            return
        }
        lookUp(query)
    }

    /// 重新查: a fresh lookup of what's shown (Claude included).
    @objc private func refresh() {
        guard let query = state?.query else { return }
        field.stringValue = query
        lookUp(query)
    }

    private func lookUp(_ query: String) {
        generation += 1
        let gen = generation
        let language = TypedLanguage.detect(query)
        state = State(query: query, language: language)
        render()
        if soundEnabled() { speak(query, language: language) }

        // Kept once both results are in, whether or not the window is still up.
        let record = RecordDraft(HistoryRecord(query: query, language: language.rawValue, date: Date(),
                                               source: .typed, appName: previousApp?.localizedName,
                                               bundleID: previousApp?.bundleIdentifier),
                                 into: history)
        let dictionaryText = self.dictionaryText
        Task.detached(priority: .userInitiated) {
            let text = dictionaryText?(query, language)
            await MainActor.run {
                record.dictionary(text)
                self.update(gen) { $0.dictionary = .done(text) }
            }
        }
        Task {
            let (result, timing) = await ClaudeTranslator.translate(query, from: language) { partial in
                self.update(gen) { $0.claudePartial = partial }
            }
            record.claude(try? result.get(), timing: timing)
            self.update(gen) { $0.claude = .done(result) }
            if case .failure = result { self.translateInstead(query, from: language, gen) }
        }
    }

    /// A word from the list: its saved results, no API call. With no Claude answer saved
    /// (looked up offline every time) it's looked up again.
    private func open(_ record: HistoryRecord) {
        field.stringValue = record.query
        guard let claude = history?.savedClaude(record.query) else {
            lookUp(record.query)
            return
        }
        generation += 1
        var opened = State(query: record.query, language: record.typedLanguage)
        opened.dictionary = .done(record.dictionary)
        opened.claude = .done(.success(claude))
        opened.stored = true
        state = opened
        render()
        field.currentEditor()?.selectAll(nil)
        if soundEnabled() { speak(record.query, language: record.typedLanguage) }
    }

    @objc private func toggleFavorite() {
        guard let query = state?.query, let history else { return }
        history.setFavorite(!history.isFavorite(query), for: query)
        updateButtons()
    }

    /// Claude gave nothing: macOS's offline translation into the other two languages.
    @MainActor
    private func translateInstead(_ query: String, from language: TypedLanguage, _ gen: Int) {
        let targets = TypedLanguage.displayOrder.filter { $0 != language }
        update(gen) { state in
            for target in targets { state.translations[target] = .loading }
        }
        for target in targets {
            Task {
                let text = await Self.translate(query, from: language, to: target)
                self.update(gen) { $0.translations[target] = .done(text) }
            }
        }
    }

    @MainActor
    private func update(_ gen: Int, _ change: (inout State) -> Void) {
        guard gen == generation, state != nil else { return }
        change(&state!)
        render()
    }

    /// Apple's on-device translation (the languages under System Settings → General →
    /// Language & Region → Translation Languages). Text, or why there is none.
    private static func translate(_ text: String, from source: TypedLanguage,
                                  to target: TypedLanguage) async -> String {
        guard #available(macOS 26.0, *) else { return "（需要 macOS 26 以上）" }
        let from = Locale.Language(identifier: source.localeID)
        let to = Locale.Language(identifier: target.localeID)
        // Inside the .app `status` can say .supported for packs that are installed
        // (the command line sees .installed), so try first and only explain on failure.
        do {
            let session: TranslationSession
            if #available(macOS 26.4, *) {
                // Without this the .app (built for macOS 14) gets the "Traditional"
                // engine, whose packs aren't installed; highFidelity is the on-device AI
                // engine the system already has.
                session = TranslationSession(installedSource: from, target: to,
                                             preferredStrategy: .highFidelity)
            } else {
                session = TranslationSession(installedSource: from, target: to)
            }
            return try await session.translate(text).targetText
        } catch {
            NSLog("HoverDict: translate \(source.rawValue)→\(target.rawValue) failed: \(error)")
            switch await LanguageAvailability().status(from: from, to: to) {
            case .unsupported:
                return "（系统翻译不支持\(source.name)→\(target.name)）"
            default:
                return "（\(source.name)→\(target.name)离线翻译不可用：System Settings → General → Language & Region → Translation Languages 里下载语言包）"
            }
        }
    }

    // MARK: - Rendering

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        listRows = []
        updateButtons()
        guard let state else {
            if field.stringValue.isEmpty { renderList() }
            resize()
            return
        }
        // The dictionary (local, in well under a second) shows only when it has the word, so
        // Chinese input or a name it lacks leaves just Claude's card — no "nothing found".
        var cards: [NSAttributedString] = []
        if case .done(let text?) = state.dictionary { cards.append(dictionaryCard(text)) }
        cards.append(claudeCard(state))
        for content in cards {
            let card = CardView(text: content, delegate: self)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        resize()
    }

    /// The star and 重新查 only with a result; the star filled in mauve when it's starred.
    private func updateButtons() {
        starButton.isHidden = state == nil || history == nil
        refreshButton.isHidden = state?.stored != true
        let starred = state.map { history?.isFavorite($0.query) ?? false } ?? false
        starButton.image = Self.symbol(starred ? "star.fill" : "star", size: 13, weight: .regular)
        starButton.contentTintColor = starred ? DeckTheme.accent : DeckTheme.text3
        starButton.toolTip = starred ? "取消收藏" : "收藏"
    }

    /// The empty field: 收藏 and 最近 (I-29), each row the word and its first meaning, no
    /// lines between them. Nothing at all when there's no history yet.
    private func renderList() {
        guard let history else { return }
        let groups = [("收藏", history.favorites), ("最近", history.recent())].filter { !$0.1.isEmpty }
        for (title, records) in groups {
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 0
            list.translatesAutoresizingMaskIntoConstraints = false
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 11, weight: .medium)
            heading.textColor = DeckTheme.text3
            let headingBox = NSView()
            headingBox.translatesAutoresizingMaskIntoConstraints = false
            heading.translatesAutoresizingMaskIntoConstraints = false
            headingBox.addSubview(heading)
            NSLayoutConstraint.activate([
                heading.leadingAnchor.constraint(equalTo: headingBox.leadingAnchor, constant: HistoryRowView.padding),
                heading.topAnchor.constraint(equalTo: headingBox.topAnchor, constant: 2),
                heading.bottomAnchor.constraint(equalTo: headingBox.bottomAnchor, constant: -4),
            ])
            list.addArrangedSubview(headingBox)
            for record in records {
                let index = listRows.count
                let row = HistoryRowView(record: record, starred: title == "收藏")
                row.onOpen = { [weak self] in self?.open(record) }
                row.onHover = { [weak self] in self?.select(index) }
                row.onUnstar = { [weak self] in
                    self?.history?.setFavorite(false, for: record.query)
                    self?.render()
                }
                row.onHide = { [weak self] in
                    self?.history?.hide(record.query)
                    self?.render()
                }
                listRows.append(row)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            headingBox.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            stack.addArrangedSubview(list)
            list.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        if let selectedRow, !listRows.indices.contains(selectedRow) { self.selectedRow = nil }
        select(selectedRow)
    }

    private func select(_ index: Int?) {
        selectedRow = index
        for (i, row) in listRows.enumerated() { row.isSelected = i == index }
    }

    /// Grow or shrink to the cards (up to `maxHeight`, then scroll), keeping the top edge.
    private func resize() {
        stack.layoutSubtreeIfNeeded()
        let content = stack.arrangedSubviews.isEmpty ? 0 : stack.fittingSize.height
        let height = min(maxHeight, inputHeight + content)
        var rect = frame
        rect.origin.y += rect.height - height
        rect.size.height = height
        setFrame(rect, display: true, animate: false)
        invalidateShadow()
    }

    private func dictionaryCard(_ text: NSAttributedString) -> NSAttributedString {
        let out = Builder()
        out.heading("词典")
        out.append(Self.restyled(text))
        return out.string
    }

    /// In Claude's place when Claude failed: the system translation, and why in small print.
    private func translationCard(_ state: State, because failure: ClaudeTranslator.Failure) -> NSAttributedString {
        let out = Builder()
        out.heading("系统翻译")
        for target in TypedLanguage.displayOrder where target != state.language {
            out.row(target)
            switch state.translations[target] {
            case .done(let text) where !text.hasPrefix("（"):
                out.word(text)
                out.speaker(text, target)
            case .done(let text): out.dim(text)
            default: out.loading()
            }
        }
        out.note(Self.reason(failure))
        return out.string
    }

    private static func reason(_ failure: ClaudeTranslator.Failure) -> String {
        switch failure {
        case .noKey: return "没有 Claude API key：菜单栏 HoverDict → Claude API key…"
        case .refused: return "Claude 没有回答这个词"
        case .unreadable: return "Claude 的回答读不出来"
        case .http(let code, let detail):
            return code == 0 ? "Claude：\(detail)" : "Claude API 出错（\(code)）\(detail.isEmpty ? "" : "：" + detail)"
        }
    }

    private func claudeCard(_ state: State) -> NSAttributedString {
        if case .done(.failure(let failure)) = state.claude {
            return translationCard(state, because: failure)
        }
        let out = Builder()
        out.heading("Claude")
        switch state.claude {
        case .loading, .done(.failure):
            // While it's written: the senses so far, and "…" where the model line will be.
            if let partial = state.claudePartial {
                senses(partial, into: out)
                out.note("…")
            } else {
                out.loading()
            }
        case .done(.success(let translation)):
            senses(translation, into: out)
            if !translation.note.isEmpty {
                out.paragraph(translation.note)
            }
            out.meta(translation.model.displayName,
                     detail: translation.seconds.map { String(format: "%.1f s", $0) })
        }
        return out.string
    }

    /// Each language's row, one sense a line; the speaker reads the first.
    private func senses(_ translation: ClaudeTranslation, into out: Builder) {
        for language in TypedLanguage.displayOrder {
            let senses = Sense.split(translation.text(for: language))
            guard !senses.isEmpty else { continue }
            out.row(language)
            for (index, sense) in senses.enumerated() {
                if index > 0 { out.continuation() }
                out.word(sense.word)
                if let gloss = sense.gloss { out.gloss(gloss) }
                if index == 0 { out.speaker(sense.word, language) }
            }
        }
    }

    /// The dictionary text was made for the hover popup (system label colors, 12–13 pt):
    /// put it in Deck's colors, at Deck's body size.
    private static func restyled(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: out.length)
        // The popup marks labels (词表, 名词, phonetics) by a smaller font, not one color.
        out.enumerateAttribute(.font, in: whole) { value, range, _ in
            let small = ((value as? NSFont)?.pointSize ?? 13) < 13
            out.addAttribute(.foregroundColor, value: small ? DeckTheme.text3 : DeckTheme.text, range: range)
        }
        out.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let resized = NSFontManager.shared.convert(font, toSize: font.pointSize + 0.5)
            out.addAttribute(.font, value: resized, range: range)
        }
        return out
    }

    // MARK: - Speech

    fileprivate static func speakURL(_ text: String, _ language: TypedLanguage) -> URL? {
        var comps = URLComponents()
        comps.scheme = "hoverdict-speak"
        comps.host = language.rawValue
        comps.queryItems = [.init(name: "t", value: text)]
        return comps.url
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "hoverdict-speak",
              let language = url.host.flatMap(TypedLanguage.init(rawValue:)),
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "t" })?.value else { return false }
        speak(text, language: language)
        return true
    }

    @objc private func speakQuery() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        speak(query, language: TypedLanguage.detect(query))
    }

    /// The user's Claude voice; Google's voice (cached) when it can't be reached, then the
    /// system voice when offline.
    private func speak(_ text: String, language: TypedLanguage) {
        synthesizer.stopSpeaking(at: .immediate)
        ClaudeVoice.shared.play(text, language: language) { [weak self] in
            TTSPlayer.shared.play(text, language: language.ttsCode) {
                let utterance = AVSpeechUtterance(string: text)
                utterance.voice = AVSpeechSynthesisVoice(language: language.voiceID)
                self?.synthesizer.speak(utterance)
            }
        }
    }

    fileprivate static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
    }
}

// MARK: - Pieces

/// Builds one card's text in Deck's type: a small dim heading; rows of a language label and
/// names, the names lined up on a tab stop (wrapped and further lines too); notes under them.
private final class Builder {
    let string = NSMutableAttributedString()
    private var started = false
    /// Right after a row's label: a dim note goes on the same line.
    private var labelled = false
    private var style = Builder.style()

    /// Where names start after the 中 / 日 / 英 label.
    private static let column: CGFloat = 24

    private static func style(indent: CGFloat = 0, before: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacingBefore = before
        style.headIndent = indent
        style.tabStops = indent > 0 ? [NSTextTab(textAlignment: .left, location: indent)] : []
        style.defaultTabInterval = column
        return style
    }

    private func add(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                     color: NSColor = DeckTheme.text) {
        string.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]))
    }

    /// Starts a new paragraph (none before the first).
    private func paragraph(style: NSParagraphStyle) {
        if started { add("\n", size: DeckTheme.bodySize) }
        self.style = style
        started = true
        labelled = false
    }

    func append(_ text: NSAttributedString) {
        paragraph(style: Self.style(before: 4))
        string.append(text)
    }

    func heading(_ text: String) {
        paragraph(style: Self.style())
        add(text, size: 11, weight: .medium, color: DeckTheme.text3)
    }

    /// A language's row: its label, then (after `word` …) its names.
    func row(_ language: TypedLanguage) {
        paragraph(style: Self.style(indent: Self.column, before: 4))
        add(language.name + "\t", size: 12, color: DeckTheme.text3)
        labelled = true
    }

    /// Another line of the same row, lined up under its first name.
    func continuation() {
        paragraph(style: Self.style(indent: Self.column))
        add("\t", size: 12)
    }

    func word(_ text: String) { add(text, size: DeckTheme.bodySize + 0.5) }

    /// The explanation that was in brackets after a name.
    func gloss(_ text: String) { add("  " + text, size: 12.5, color: DeckTheme.text2) }

    func dim(_ text: String) {
        if !labelled { paragraph(style: Self.style(before: 4)) }
        add(text, size: 12.5, color: DeckTheme.text3)
    }

    func loading() { dim("…") }

    /// A note or introduction under the names, a little apart from them.
    func paragraph(_ text: String) {
        paragraph(style: Self.style(before: 8))
        add(text, size: 12.5, color: DeckTheme.text2)
    }

    /// Small print at the end: the model that answered, in the accent, and how long it
    /// took, dimmer.
    func meta(_ text: String, detail: String? = nil) {
        paragraph(style: Self.style(before: 6))
        add(text, size: 11, color: DeckTheme.accent)
        if let detail { add(" · " + detail, size: 11, color: DeckTheme.text3) }
    }

    /// Small dim print at the end: why a card is what it is.
    func note(_ text: String) {
        paragraph(style: Self.style(before: 6))
        add(text, size: 11, color: DeckTheme.text3)
    }

    /// A speaker icon after a name; clicking it reads the name (LookupWindow handles the link).
    func speaker(_ text: String, _ language: TypedLanguage) {
        let attachment = NSTextAttachment()
        let image = LookupWindow.symbol("speaker.wave.2", size: 11, weight: .regular)
        image.isTemplate = true
        attachment.image = image.tinted(DeckTheme.accent)
        attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
        add("  ", size: 12)
        let icon = NSMutableAttributedString(attachment: attachment)
        var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
        if let link = LookupWindow.speakURL(text, language) { attributes[.link] = link }
        icon.addAttributes(attributes, range: NSRange(location: 0, length: icon.length))
        string.append(icon)
    }
}

/// Collects one ⌥Z lookup's results and appends it to the history once both are in.
@MainActor
private final class RecordDraft {
    private var record: HistoryRecord
    private weak var history: LookupHistory?
    private var pending = 2

    init(_ record: HistoryRecord, into history: LookupHistory?) {
        self.record = record
        self.history = history
    }

    func dictionary(_ text: NSAttributedString?) {
        record.dictionaryRTF = HistoryRecord.rtf(text)
        finish()
    }

    func claude(_ translation: ClaudeTranslation?, timing: ClaudeTiming?) {
        record.claude = translation.map(StoredTranslation.init)
        record.claudeTiming = timing
        finish()
    }

    private func finish() {
        pending -= 1
        if pending == 0 { history?.append(record) }
    }
}

/// A word in the history list: the word, its first meaning dimmer; under the mouse or ↑↓
/// a light fill (not the system's blue). Click opens it; right-click hides it (or unstars).
private final class HistoryRowView: NSView {
    /// Text inset, the same as the cards' so the words line up with the search icon.
    static let padding: CGFloat = CardView.padding

    let record: HistoryRecord
    var onOpen: (() -> Void)?
    var onHover: (() -> Void)?
    var onHide: (() -> Void)?
    var onUnstar: (() -> Void)?
    private let starred: Bool

    var isSelected = false { didSet { needsDisplay = true } }

    init(record: HistoryRecord, starred: Bool) {
        self.record = record
        self.starred = starred
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let word = NSTextField(labelWithString: record.query)
        word.font = .systemFont(ofSize: DeckTheme.bodySize)
        word.textColor = DeckTheme.text
        word.lineBreakMode = .byTruncatingTail
        word.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        word.setContentHuggingPriority(.required, for: .horizontal)
        let summary = NSTextField(labelWithString: record.summary)
        summary.font = .systemFont(ofSize: 12.5)
        summary.textColor = DeckTheme.text3
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [word, summary] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            word.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            word.centerYAnchor.constraint(equalTo: centerYAnchor),
            word.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
            summary.leadingAnchor.constraint(equalTo: word.trailingAnchor, constant: 10),
            summary.firstBaselineAnchor.constraint(equalTo: word.firstBaselineAnchor),
            summary.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = isSelected ? DeckTheme.fill.cgColor(for: effectiveAppearance) : .clear
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = starred
            ? NSMenuItem(title: "取消收藏", action: #selector(unstar), keyEquivalent: "")
            : NSMenuItem(title: "从列表隐藏", action: #selector(hide), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func hide() { onHide?() }
    @objc private func unstar() { onUnstar?() }
}

/// One result block: Deck's light `--fill` over the glass (see-through, no edge), its text
/// selectable.
private final class CardView: NSView {
    /// Text inset from the card's edge.
    static let padding: CGFloat = 12
    private let textView = FitTextView()

    init(text: NSAttributedString, delegate: NSTextViewDelegate) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DeckTheme.cardRadius
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.selectedTextAttributes = [.backgroundColor: DeckTheme.accent.withAlphaComponent(0.2)]
        textView.focusRingType = .none
        textView.delegate = delegate
        textView.textStorage?.setAttributedString(text)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        let pad = Self.padding
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor, constant: pad - 2),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = DeckTheme.fill.cgColor(for: effectiveAppearance)
    }
    override var wantsUpdateLayer: Bool { true }
}

/// An NSTextView that is as tall as its text at the width it's given.
private final class FitTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }
}

/// A plain fill that follows light / dark, with the sheet's corners.
private final class TintView: NSView {
    private let color: NSColor
    init(color: NSColor, radius: CGFloat) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor(for: effectiveAppearance) }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private extension NSColor {
    func cgColor(for appearance: NSAppearance) -> CGColor {
        var result = cgColor
        appearance.performAsCurrentDrawingAppearance { result = self.cgColor }
        return result
    }
}

private extension NSImage {
    /// A template symbol drawn in `color` (attachments don't take a tint).
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

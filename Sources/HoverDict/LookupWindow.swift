import AppKit
import AVFoundation
import Translation

/// The typed-lookup window (⌥⇧D): type a word or term in 中 / 日 / 英, press Return, and
/// get cards — the dictionaries HoverDict already has, macOS's offline translation into the
/// other two languages, Claude's translation with every main sense, and the term's Wikipedia
/// names in all three with a short introduction. Every name has a speaker that reads it in
/// the user's Claude voice.
///
/// Looks like Agent Deck's Finder (N-006): a borderless sheet of frosted glass with Deck's
/// Warm tint, 14 px corners, the input bare on top, results as 10 px cards 8 px apart — no
/// title bar, separator lines or colored edges.
final class LookupWindow: NSPanel, NSTextFieldDelegate, NSTextViewDelegate {

    /// The dictionary block for a query (call off the main thread); nil = nothing found.
    var dictionaryText: ((String, TypedLanguage) -> NSAttributedString?)?
    /// Whether to read the query aloud when it's looked up (menu 朗读发声).
    var soundEnabled: () -> Bool = { true }

    private let width: CGFloat = 560
    private let inputHeight: CGFloat = 54
    private let maxHeight: CGFloat = 620

    private let field = NSTextField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let synthesizer = AVSpeechSynthesizer()

    /// Bumped per query, so a slow answer for an earlier one is dropped.
    private var generation = 0
    private var state: State?

    private enum Pending<T> {
        case loading
        case done(T)
    }

    private struct State {
        var query: String
        var language: TypedLanguage
        var dictionary: Pending<NSAttributedString?> = .loading
        var translations: [TypedLanguage: Pending<String>] = [:]
        var claude: Pending<Result<ClaudeTranslation, ClaudeTranslator.Failure>> = .loading
        var wiki: Pending<WikiTerm?> = .loading
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
        // Deck's Glass: macOS's frosted material with the sheet tint over it.
        let glass = NSVisualEffectView()
        glass.material = .fullScreenUI
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = DeckTheme.sheetRadius
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true

        let tint = TintView(color: DeckTheme.sheetBackground)
        tint.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(tint)

        let icon = NSImageView(image: Self.symbol("magnifyingglass", size: 15, weight: .medium))
        icon.contentTintColor = DeckTheme.text3
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.textColor = DeckTheme.text
        field.placeholderAttributedString = NSAttributedString(
            string: "中文、日本語、English",
            attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: DeckTheme.text3])
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false

        let speak = NSButton(image: Self.symbol("speaker.wave.2", size: 14, weight: .regular),
                             target: self, action: #selector(speakQuery))
        speak.isBordered = false
        speak.contentTintColor = DeckTheme.text3
        speak.toolTip = "朗读"
        speak.focusRingType = .none
        speak.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DeckTheme.gap
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 12)
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

        for view in [icon, field, speak, scroll] as [NSView] { glass.addSubview(view) }
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: glass.topAnchor),
            tint.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: glass.trailingAnchor),

            icon.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: glass.topAnchor, constant: inputHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            speak.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            speak.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -16),
            speak.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            speak.widthAnchor.constraint(equalToConstant: 24),

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

    // MARK: - Show / hide

    /// ⌥⇧D: bring the window up with the last query selected (typing replaces it), or put
    /// it away when it's already in front.
    func toggle() {
        if isVisible && isKeyWindow {
            close()
            return
        }
        if !isVisible { placeOnMouseScreen() }
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Clicking anywhere else puts it away, like Deck's Finder and Spotlight.
    override func resignKey() {
        super.resignKey()
        if isVisible { close() }
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
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
        return false
    }

    // MARK: - Lookup

    @objc private func submit() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        generation += 1
        let gen = generation
        let language = TypedLanguage.detect(query)
        var fresh = State(query: query, language: language)
        let targets = TypedLanguage.displayOrder.filter { $0 != language }
        for target in targets { fresh.translations[target] = .loading }
        state = fresh
        render()
        if soundEnabled() { speak(query, language: language) }

        let dictionaryText = self.dictionaryText
        Task.detached(priority: .userInitiated) {
            let text = dictionaryText?(query, language)
            await MainActor.run { self.update(gen) { $0.dictionary = .done(text) } }
        }
        for target in targets {
            Task {
                let text = await Self.translate(query, from: language, to: target)
                self.update(gen) { $0.translations[target] = .done(text) }
            }
        }
        Task {
            let result = await ClaudeTranslator.translate(query, from: language)
            self.update(gen) { $0.claude = .done(result) }
        }
        Task {
            let term = await WikiTerms.lookup(query, language: language)
            self.update(gen) { $0.wiki = .done(term) }
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
        guard let state else {
            resize()
            return
        }
        let cards = [dictionaryCard(state), translationCard(state), claudeCard(state), wikiCard(state)]
        for content in cards {
            let card = CardView(text: content, delegate: self)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
        resize()
    }

    /// Grow or shrink to the cards (up to `maxHeight`, then scroll), keeping the top edge.
    private func resize() {
        stack.layoutSubtreeIfNeeded()
        let content = state == nil ? 0 : stack.fittingSize.height
        let height = min(maxHeight, inputHeight + content)
        var rect = frame
        rect.origin.y += rect.height - height
        rect.size.height = height
        setFrame(rect, display: true, animate: false)
        invalidateShadow()
    }

    private func dictionaryCard(_ state: State) -> NSAttributedString {
        let out = Builder()
        out.heading("词典")
        switch state.dictionary {
        case .loading: out.loading()
        case .done(let text?): out.append(Self.restyled(text))
        case .done(nil):
            out.add(state.language == .zh ? "词典只有英→中、日→中，中文看下面的翻译" : "没有释义",
                    size: 13, color: DeckTheme.text3)
        }
        return out.string
    }

    private func translationCard(_ state: State) -> NSAttributedString {
        let out = Builder()
        out.heading("系统翻译")
        var first = true
        for target in TypedLanguage.displayOrder where target != state.language {
            if !first { out.newline() }
            first = false
            out.add(target.name + "  ", size: 13, color: DeckTheme.text3)
            switch state.translations[target] {
            case .done(let text) where !text.hasPrefix("（"):
                out.add(text, size: 16, weight: .medium)
                out.speaker(text, target)
            case .done(let text): out.add(text, size: 13, color: DeckTheme.text3)
            default: out.loading()
            }
        }
        return out.string
    }

    private func claudeCard(_ state: State) -> NSAttributedString {
        let out = Builder()
        out.heading("Claude")
        switch state.claude {
        case .loading: out.loading()
        case .done(.failure(let failure)):
            let message: String
            switch failure {
            case .noKey: message = "菜单栏 HoverDict → Claude API key… 填入 key 后，这里显示 Claude 的翻译"
            case .refused: message = "Claude 没有回答这个词"
            case .unreadable: message = "Claude 的回答读不出来"
            case .http(let code, let detail):
                message = code == 0 ? detail : "API 出错（\(code)）\(detail.isEmpty ? "" : "：" + detail)"
            }
            out.add(message, size: 13, color: DeckTheme.text3)
        case .done(.success(let translation)):
            var first = true
            for language in TypedLanguage.displayOrder {
                let text = translation.text(for: language)
                guard !text.isEmpty else { continue }
                if !first { out.newline() }
                first = false
                out.add(language.name + "  ", size: 13, color: DeckTheme.text3)
                out.add(text, size: 16, weight: .medium)
                // Read the first sense only: "变压器；Transformer 模型" → "变压器".
                let firstSense = text.split(whereSeparator: { $0 == "；" || $0 == ";" }).first.map(String.init) ?? text
                out.speaker(firstSense.trimmingCharacters(in: .whitespaces), language)
            }
            if !translation.note.isEmpty {
                out.paragraph(translation.note)
            }
        }
        return out.string
    }

    private func wikiCard(_ state: State) -> NSAttributedString {
        let out = Builder()
        out.heading("Wikipedia")
        switch state.wiki {
        case .loading: out.loading()
        case .done(nil): out.add("没有这个词条，或连不上网", size: 13, color: DeckTheme.text3)
        case .done(let term?):
            var first = true
            for language in TypedLanguage.displayOrder {
                if !first { out.newline() }
                first = false
                out.add(language.name + "  ", size: 13, color: DeckTheme.text3)
                if let title = term.titles[language] {
                    out.add(title, size: 16, weight: .medium)
                    out.speaker(title, language)
                } else {
                    out.add("—", size: 13, color: DeckTheme.text3)
                }
            }
            if let summary = term.summary {
                out.paragraph(summary)
            }
        }
        return out.string
    }

    /// The dictionary text was made for the hover popup (system label colors, 12–13 pt):
    /// put it in Deck's colors, a size up.
    private static func restyled(_ text: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            let color = value as? NSColor
            let mapped: NSColor = color == .secondaryLabelColor || color == .tertiaryLabelColor
                ? DeckTheme.text2 : DeckTheme.text
            out.addAttribute(.foregroundColor, value: mapped, range: range)
        }
        out.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let resized = NSFontManager.shared.convert(font, toSize: font.pointSize + 1)
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

/// Builds one card's text in Deck's type: a small dim heading, then the content.
private final class Builder {
    let string = NSMutableAttributedString()

    private func paragraphStyle(spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacingBefore = spacingBefore
        return style
    }

    func add(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
             color: NSColor = DeckTheme.text, link: URL? = nil) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(),
        ]
        if let link { attributes[.link] = link }
        string.append(NSAttributedString(string: text, attributes: attributes))
    }

    func append(_ text: NSAttributedString) { string.append(text) }

    func newline() { add("\n", size: 13) }

    func heading(_ text: String) {
        add(text + "\n", size: 11.5, weight: .semibold, color: DeckTheme.text3)
    }

    func loading() { add("…", size: 13, color: DeckTheme.text3) }

    /// A note or introduction under the names, a little apart from them.
    func paragraph(_ text: String) {
        string.append(NSAttributedString(string: "\n" + text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: DeckTheme.text2,
            .paragraphStyle: paragraphStyle(spacingBefore: 6),
        ]))
    }

    /// A speaker icon after a name; clicking it reads the name (LookupWindow handles the link).
    func speaker(_ text: String, _ language: TypedLanguage) {
        let attachment = NSTextAttachment()
        let image = LookupWindow.symbol("speaker.wave.2", size: 12, weight: .regular)
        image.isTemplate = true
        attachment.image = image.tinted(DeckTheme.text3)
        attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
        add("  ", size: 13)
        let icon = NSMutableAttributedString(attachment: attachment)
        if let link = LookupWindow.speakURL(text, language) {
            icon.addAttribute(.link, value: link, range: NSRange(location: 0, length: icon.length))
        }
        string.append(icon)
    }
}

/// One result block: a rounded fill a shade off the sheet, its text selectable.
private final class CardView: NSView {
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
        textView.selectedTextAttributes = [.backgroundColor: DeckTheme.fill.withAlphaComponent(0.25)]
        textView.focusRingType = .none
        textView.delegate = delegate
        textView.textStorage?.setAttributedString(text)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
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

/// A plain fill that follows light / dark.
private final class TintView: NSView {
    private let color: NSColor
    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
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

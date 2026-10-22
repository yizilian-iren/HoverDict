import AppKit
import AVFoundation
import Translation

/// The typed-lookup window (⌥⇧D): type a word or term in 中 / 日 / 英, press Return, and
/// get three blocks — the dictionaries HoverDict already has, macOS's offline translation
/// into the other two languages, and the term's Wikipedia names in all three with a
/// short introduction. Every translation and name has a 🔊 that reads it aloud.
final class LookupWindow: NSPanel, NSTextFieldDelegate, NSTextViewDelegate {

    /// The dictionary block for a query (call off the main thread); nil = nothing found.
    var dictionaryText: ((String, TypedLanguage) -> NSAttributedString?)?
    /// Whether to read the query aloud when it's looked up (menu 朗读发声).
    var soundEnabled: () -> Bool = { true }

    private let field = NSTextField()
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private let synthesizer = AVSpeechSynthesizer()

    /// Bumped per query, so a slow answer for an earlier one is dropped.
    private var generation = 0
    private var state = State(query: "", language: .en)

    private enum Pending<T> {
        case loading
        case done(T)
    }

    private struct State {
        var query: String
        var language: TypedLanguage
        var dictionary: Pending<NSAttributedString?> = .loading
        var translations: [TypedLanguage: Pending<String>] = [:]
        var wiki: Pending<WikiTerm?> = .loading
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered,
                   defer: true)
        title = "HoverDict 查词（中 / 日 / 英）"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        minSize = NSSize(width: 360, height: 240)
        buildContent()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func buildContent() {
        let content = NSView()

        field.placeholderString = "输入中文、日本語或 English，回车查"
        field.font = .systemFont(ofSize: 16)
        field.bezelStyle = .roundedBezel
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.translatesAutoresizingMaskIntoConstraints = false

        let speakButton = NSButton(title: "🔊", target: self, action: #selector(speakQuery))
        speakButton.bezelStyle = .rounded
        speakButton.toolTip = "朗读输入的词"
        speakButton.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.delegate = self
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]

        content.addSubview(field)
        content.addSubview(speakButton)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            speakButton.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            speakButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            speakButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        contentView = content
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

    private func placeOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        else { return }
        let area = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(x: area.midX - size.width / 2,
                               y: area.minY + area.height * 0.62 - size.height / 2))
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
        state = State(query: query, language: language)
        let targets = TypedLanguage.allCases.filter { $0 != language }
        for target in targets { state.translations[target] = .loading }
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
            let term = await WikiTerms.lookup(query, language: language)
            self.update(gen) { $0.wiki = .done(term) }
        }
    }

    @MainActor
    private func update(_ gen: Int, _ change: (inout State) -> Void) {
        guard gen == generation else { return }
        change(&state)
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
        let out = NSMutableAttributedString()
        func add(_ string: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                 color: NSColor = .labelColor, link: URL? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: color,
            ]
            if let link { attributes[.link] = link }
            out.append(NSAttributedString(string: string, attributes: attributes))
        }
        func heading(_ string: String) {
            if out.length > 0 { add("\n\n") }
            add(string + "\n", size: 11, weight: .semibold, color: .secondaryLabelColor)
        }
        func speaker(_ text: String, _ language: TypedLanguage) {
            add("  🔊", size: 12, link: Self.speakURL(text, language))
        }
        let loading = { add("查询中…", color: .tertiaryLabelColor) }

        heading("词典")
        switch state.dictionary {
        case .loading: loading()
        case .done(let text?): out.append(text)
        case .done(nil):
            add(state.language == .zh ? "（词典只有英→中、日→中；中文看下面的翻译）" : "（未找到释义）",
                color: .secondaryLabelColor)
        }

        heading("翻译（macOS 离线）")
        for target in TypedLanguage.displayOrder where target != state.language {
            add(target.name + "  ", color: .secondaryLabelColor)
            switch state.translations[target] {
            case .done(let text) where !text.hasPrefix("（"):
                add(text, size: 15)
                speaker(text, target)
            case .done(let text): add(text, color: .secondaryLabelColor)
            default: loading()
            }
            add("\n")
        }
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }

        heading("科技名词（Wikipedia）")
        switch state.wiki {
        case .loading: loading()
        case .done(nil): add("（Wikipedia 上没找到这个词条，或连不上网）", color: .secondaryLabelColor)
        case .done(let term?):
            for language in TypedLanguage.displayOrder {
                add(language.name + "  ", color: .secondaryLabelColor)
                if let title = term.titles[language] {
                    add(title, size: 15, weight: .medium)
                    speaker(title, language)
                } else {
                    add("—", color: .tertiaryLabelColor)
                }
                add("\n")
            }
            if let summary = term.summary {
                add(summary, size: 12, color: .secondaryLabelColor)
            }
        }

        textView.textStorage?.setAttributedString(out)
    }

    // MARK: - Speech

    private static func speakURL(_ text: String, _ language: TypedLanguage) -> URL? {
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

    /// Google's voice (cached) like the hover popup; the system voice when offline.
    private func speak(_ text: String, language: TypedLanguage) {
        synthesizer.stopSpeaking(at: .immediate)
        TTSPlayer.shared.play(text, language: language.ttsCode) { [weak self] in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: language.voiceID)
            self?.synthesizer.speak(utterance)
        }
    }
}

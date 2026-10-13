import AppKit
import AVFoundation
import QuartzCore

/// The hover popup: a compact, non-activating, pass-through floating panel. English shows
/// ONLY the Chinese — a few Oxford senses on one line, or the collapsed ECDICT translation
/// when Oxford has no entry — no headword, no phonetic; Japanese adds a
/// headword + kana line, since the reading is the point. The word is auto-spoken when the
/// popup appears. The panel ignores the mouse entirely, and the
/// pipeline dismisses it (with a fade) as soon as the cursor moves.
final class OverlayPanel: NSPanel {

    private let translationLabel = NSTextField(wrappingLabelWithString: "")
    // Must be retained for the lifetime of speech, otherwise it deallocates mid-utterance.
    private let synthesizer = AVSpeechSynthesizer()

    /// The word to pronounce (English word, or Japanese kana reading).
    private(set) var spokenWord: String = ""
    /// Tracks the currently displayed word so we auto-speak only when it CHANGES,
    /// not every time the pipeline re-fires on the same word.
    private var lastShownWord: String?
    /// Pending auto-speak; cancelled if the cursor moves to another word first.
    private var speakTimer: Timer?
    /// Dwell time on a word before auto-speaking, to avoid blasting audio while the
    /// cursor sweeps across text.
    private let speakDelay: TimeInterval = 0.5
    /// Master mute switch (toggled from the menu bar, persisted by AppDelegate). When
    /// false, hovering still shows the popup but nothing is spoken.
    var soundEnabled = true

    /// Bumped on each show/hide so in-flight fade completions don't clobber a newer state.
    private var fadeGeneration = 0
    /// True while a fade-out is in progress; avoids restarting the animation on every move.
    private var isFadingOut = false
    private let fadeInDuration: TimeInterval = 0.12
    private let fadeOutDuration: TimeInterval = 0.18

    /// Background translucency (0 = invisible, 1 = opaque). Text stays fully opaque.
    private let backgroundAlpha: CGFloat = 0.99

    /// The popup width adapts to the text, between these bounds; only past the max does
    /// the translation wrap onto more lines.
    private let minContentWidth: CGFloat = 90
    private let maxContentWidth: CGFloat = 360
    private let hMargin: CGFloat = 12
    private let vMargin: CGFloat = 10

    /// How many comma-separated senses of the primary meaning to keep when collapsing.
    private let maxSenses = 2

    private var container: NSView!
    /// Updated each `show(...)` to size the popup to its content.
    private var widthConstraint: NSLayoutConstraint!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
            // .nonactivatingPanel + .borderless: a passive tooltip that never steals focus.
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // `.floating` sits under fullscreen app windows; `.mainMenu` is the usual
        // level that still paints above another app's fullscreen Space.
        level = .mainMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        // Pass-through / non-selectable: the popup never intercepts the mouse. Combined
        // with the pipeline hiding it when the cursor enters its frame, moving onto the
        // popup just makes it vanish.
        ignoresMouseEvents = true
        // Do NOT use `.stationary` — it can leave the panel stranded on the desktop
        // Space when an app enters fullscreen (popup "missing" until fullscreen toggled).
        applyFullscreenFriendlyBehavior()

        // Space / fullscreen transitions can detach the panel; re-assert on change.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        buildContentView()
    }

    /// Collection behavior that lets the panel appear on every Space, including
    /// another app's fullscreen Space.
    private func applyFullscreenFriendlyBehavior() {
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Re-assert level in case a Space transition reset stacking.
        level = .mainMenu
    }

    @objc private func activeSpaceDidChange() {
        applyFullscreenFriendlyBehavior()
        // If we were visible when the user entered/left fullscreen, bring the panel
        // onto the new Space; otherwise the next show() will place it correctly.
        if isVisible {
            orderFrontRegardless()
        }
    }

    private func buildContentView() {
        container = NSView()

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        // Make ONLY the background more see-through; the text stays a separate layer on
        // top, so it remains fully opaque and readable. Lower = more transparent.
        effect.alphaValue = backgroundAlpha
        effect.translatesAutoresizingMaskIntoConstraints = false

        // Chinese translation fills the whole popup.
        translationLabel.font = .systemFont(ofSize: 13)
        translationLabel.textColor = .labelColor
        translationLabel.maximumNumberOfLines = 3      // collapse: cap the box height
        translationLabel.lineBreakMode = .byTruncatingTail
        translationLabel.preferredMaxLayoutWidth = maxContentWidth - hMargin * 2
        translationLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(effect)
        container.addSubview(translationLabel)

        // Width is set per-show() to fit the content (see show()).
        widthConstraint = container.widthAnchor.constraint(equalToConstant: maxContentWidth)

        NSLayoutConstraint.activate([
            widthConstraint,

            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            translationLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: hMargin),
            translationLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -hMargin),
            translationLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: vMargin),
            translationLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vMargin),
        ])

        contentView = container
    }

    /// Show the popup just below `cursorGlobal` (AppKit global, bottom-left, points).
    /// `word` is the recognized word (used for pronunciation); `entry` is the dictionary
    /// result (may be nil). `preferredPOS` steers which ECDICT sense line to show when
    /// the local context suggests a part of speech.
    /// - Hover: auto-speaks only when the word changes (after a short dwell).
    /// - Click (`forceSpeak`): speaks immediately — including a re-click of the same word.
    func show(word: String,
              entry: DictionaryEntry?,
              preferredPOS: SensePicker.POSKind? = nil,
              forceSpeak: Bool = false,
              below cursorGlobal: CGPoint) {
        let text: String
        if let translation = entry?.translation {
            text = Self.collapse(translation, maxSenses: maxSenses, preferredPOS: preferredPOS)
        } else {
            text = "（未找到释义）"
        }
        translationLabel.maximumNumberOfLines = 3      // collapse: cap the box height
        translationLabel.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ])
        present(speaking: word, language: "en", forceSpeak: forceSpeak, below: cursorGlobal)
    }

    /// English popup from the Oxford dictionary, as short as ECDICT's: one line, the
    /// first rendering of each sense — 「对…不予考虑；彻底忘掉；解雇」. The editors' sense
    /// labels ("(reject)") are left out; the user found them too long.
    func show(word: String,
              senses: [OxfordSense],
              forceSpeak: Bool = false,
              below cursorGlobal: CGPoint) {
        show(word: word, text: Self.oxfordText(senses), forceSpeak: forceSpeak, below: cursorGlobal)
    }

    /// English popup with ready-made text: a glossary entry, or Oxford's one line.
    func show(word: String,
              text: String,
              forceSpeak: Bool = false,
              below cursorGlobal: CGPoint) {
        translationLabel.maximumNumberOfLines = 3      // only a very long line wraps
        translationLabel.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ])
        present(speaking: word, language: "en", forceSpeak: forceSpeak, below: cursorGlobal)
    }

    /// 「记录、记载」「履历、历史」「唱片」 → 「记录；履历；唱片」 (repeats dropped).
    static func oxfordText(_ senses: [OxfordSense]) -> String {
        var seen = Set<String>()
        return senses
            .compactMap { sense in
                sense.translation.split(separator: "、").first
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: "；")
    }

    /// Expanded English popup (Shift): the glossary line and Oxford's senses with their
    /// labels under each part of speech (ECDICT's lines when Oxford lacks the word) —
    /// for when the one-liner doesn't fit the sentence.
    func showDetail(word: String,
                    text: NSAttributedString,
                    below cursorGlobal: CGPoint) {
        translationLabel.maximumNumberOfLines = 16
        translationLabel.attributedStringValue = text
        present(speaking: word, language: "en", forceSpeak: false, below: cursorGlobal)
    }

    /// Oxford, when it has the word, already covers what ECDICT says — ECDICT is shown
    /// only for words Oxford lacks. With several parts of speech each gets up to `perPOS`
    /// senses, so a long noun list doesn't push the verb out; a single one gets them all.
    static func detailText(glossary: String?,
                           groups: [OxfordGroup]?,
                           ecdict: String?,
                           perPOS: Int = 3,
                           maxSenses: Int = 8) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func add(_ string: String, dim: Bool = false) {
            text.append(NSAttributedString(string: string, attributes: [
                .font: NSFont.systemFont(ofSize: dim ? 12 : 13),
                .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]))
        }
        func newLine() { if text.length > 0 { add("\n") } }

        if let glossary {
            add("词表  ", dim: true)
            add(glossary)
        }

        // thread: "名词" senses, then the plural "threads" (衣服) — also a noun; one block.
        var merged: [OxfordGroup] = []
        for group in groups ?? [] {
            if let last = merged.last, last.pos == group.pos {
                merged[merged.count - 1] = OxfordGroup(pos: last.pos, senses: last.senses + group.senses)
            } else {
                merged.append(group)
            }
        }
        var budget = maxSenses
        let share = merged.count == 1 ? maxSenses : perPOS
        for group in merged where budget > 0 {
            newLine()
            add(posName(group.pos) ?? "释义", dim: true)
            for sense in group.senses.prefix(min(share, budget)) {
                newLine()
                if let label = sense.label { add(label + " ", dim: true) }
                add(sense.translation)
                budget -= 1
            }
        }

        if merged.isEmpty {
            let ecdictLines = (ecdict ?? "")
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(3)
            for line in ecdictLines {
                newLine()
                add(line)
            }
        }
        if text.length == 0 { add("（未找到释义）") }
        return text
    }

    private static func posName(_ pos: SensePicker.POSKind) -> String? {
        switch pos {
        case .noun: "名词"
        case .verb: "动词"
        case .adjective: "形容词"
        case .adverb: "副词"
        case .preposition: "介词"
        case .conjunction: "连词"
        case .pronoun: "代词"
        case .determiner: "限定词"
        case .number: "数词"
        case .other: nil
        }
    }

    /// Japanese popup: 「食べる  たべる」 on the first line, Chinese senses below.
    /// Speaks the kana reading (never the kanji, whose reading TTS might guess wrong).
    func showJapanese(_ entry: JapaneseEntry,
                      forceSpeak: Bool = false,
                      below cursorGlobal: CGPoint) {
        translationLabel.maximumNumberOfLines = 4
        translationLabel.attributedStringValue = Self.japaneseText(entry)
        present(speaking: entry.reading ?? entry.headword,
                language: "ja",
                forceSpeak: forceSpeak,
                below: cursorGlobal)
    }

    private static func japaneseText(_ entry: JapaneseEntry) -> NSAttributedString {
        let text = NSMutableAttributedString(string: entry.headword, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        if let reading = entry.reading {
            text.append(NSAttributedString(string: "  " + reading, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        let senses = entry.senses.isEmpty ? "（未找到释义）" : entry.senses.joined(separator: "；")
        text.append(NSAttributedString(string: "\n" + senses, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]))
        return text
    }

    /// Shared by both languages: speech policy, adaptive sizing, placement, fade-in.
    /// - Hover: auto-speaks only when the word changes (after a short dwell).
    /// - Click (`forceSpeak`): speaks immediately — including a re-click of the same word.
    private func present(speaking word: String,
                         language: String,
                         forceSpeak: Bool,
                         below cursorGlobal: CGPoint) {
        spokenWord = word

        let isNewWord = word.caseInsensitiveCompare(lastShownWord ?? "") != .orderedSame
        if isNewWord {
            lastShownWord = word
        }
        // Click mode: always speak now (re-click on the same word replays).
        // Hover mode: only when the word changes, after a short dwell so sweeps stay quiet.
        if forceSpeak {
            speakTimer?.invalidate()
            speak(word, language: language)
        } else if isNewWord {
            scheduleAutoSpeak(word, language: language)
        }

        // Adaptive width: fit the text up to maxContentWidth; only past that does it wrap.
        let textWidth = Self.maxLineWidth(of: translationLabel.attributedStringValue)
        let clampedTextWidth = min(textWidth, maxContentWidth - hMargin * 2)
        let panelWidth = min(max(clampedTextWidth + hMargin * 2, minContentWidth), maxContentWidth)
        widthConstraint.constant = panelWidth
        translationLabel.preferredMaxLayoutWidth = panelWidth - hMargin * 2

        // Now compute the height for that width.
        container.layoutSubtreeIfNeeded()
        let panelHeight = max(container.fittingSize.height, 38)

        // Place ABOVE the cursor. In AppKit's bottom-left global space (same space as
        // NSEvent.mouseLocation), "above" means a larger y — the panel's bottom edge sits
        // `gap` points above the cursor, so the whole panel is above it.
        let gap: CGFloat = 18
        var origin = CGPoint(x: cursorGlobal.x - 16,
                             y: cursorGlobal.y + gap)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorGlobal) }) {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - panelWidth - 4)
            // No room above → flip below the cursor.
            if origin.y + panelHeight > f.maxY - 4 {
                origin.y = cursorGlobal.y - gap - panelHeight
            }
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - panelHeight - 4)
        }

        setFrame(NSRect(x: origin.x, y: origin.y, width: panelWidth, height: panelHeight), display: true)

        // Re-bind to the active (possibly fullscreen) Space every show — Space
        // transitions otherwise leave the panel invisible on the wrong desktop.
        applyFullscreenFriendlyBehavior()

        // Cancel any in-flight fade-out; fade in when appearing from hidden.
        isFadingOut = false
        fadeGeneration += 1
        let appearing = !isVisible || alphaValue < 0.05
        if appearing {
            alphaValue = 0
            orderFrontRegardless()
            let gen = fadeGeneration
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fadeInDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            } completionHandler: { [weak self] in
                guard let self, gen == self.fadeGeneration else { return }
                self.alphaValue = 1
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
        }
    }

    /// Hide the popup. Defaults to a short fade-out; pass `animated: false` for an
    /// immediate dismiss (pause / mode switch / quit).
    func hidePanel(animated: Bool = true) {
        // Reset so moving away and back onto the same word speaks again.
        lastShownWord = nil
        speakTimer?.invalidate()

        guard isVisible else {
            isFadingOut = false
            alphaValue = 1
            return
        }
        // Already fading — let the current animation finish.
        if animated && isFadingOut { return }

        fadeGeneration += 1
        let gen = fadeGeneration

        guard animated else {
            isFadingOut = false
            orderOut(nil)
            alphaValue = 1
            return
        }

        isFadingOut = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fadeOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, gen == self.fadeGeneration else { return }
            self.isFadingOut = false
            self.orderOut(nil)
            self.alphaValue = 1
        }
    }

    /// Speak `word` after `speakDelay`, cancelling any earlier pending speech. Fast
    /// sweeps keep rescheduling, so only a word the cursor lingers on is spoken.
    private func scheduleAutoSpeak(_ word: String, language: String) {
        speakTimer?.invalidate()
        speakTimer = Timer.scheduledTimer(withTimeInterval: speakDelay, repeats: false) { [weak self] _ in
            self?.speak(word, language: language)
        }
    }

    /// `language`: "en" or "ja" (Google TTS code; the system fallback voice follows it).
    func speak(_ text: String, language: String = "en") {
        guard soundEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Cut off any system speech still running from the previous word.
        synthesizer.stopSpeaking(at: .immediate)
        // Prefer the Google TTS clip (cached, or fetched now); fall back to the system
        // voice when it can't be fetched.
        TTSPlayer.shared.play(trimmed, language: language) { [weak self] in
            guard let self else { return }
            let utterance = AVSpeechUtterance(string: trimmed)
            utterance.voice = AVSpeechSynthesisVoice(language: language == "ja" ? "ja-JP" : "en-US")
            self.synthesizer.speak(utterance)
        }
    }

    /// Reduce an ECDICT translation to just the gist: drop the part-of-speech markers
    /// (n./vt./a.…) and domain tags ([医]/[计]…), then keep only the first `maxSenses`
    /// comma-separated meanings of the chosen entry. When `preferredPOS` is set, prefer
    /// the line whose marker matches (e.g. verb → `vt.` / `vi.`); otherwise the first
    /// POS line. So "n. 苹果, 家伙\n[医] 苹果" becomes "苹果, 家伙".
    static func collapse(_ translation: String,
                         maxSenses: Int,
                         preferredPOS: SensePicker.POSKind? = nil) -> String {
        let lines = translation
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // A leading part-of-speech marker, e.g. "n. ", "vt. ", "prep. ".
        let posMarker = #/^[a-zA-Z]{1,5}\.\s*/#

        let preferredMarkers = preferredPOS.map { SensePicker.ecdictMarkers(for: $0) } ?? []
        let preferredLine: String? = preferredMarkers.isEmpty ? nil : lines.first { line in
            guard let marker = Self.ecdictMarker(in: line) else { return false }
            return preferredMarkers.contains(marker)
        }

        // Prefer context POS match → first real POS line → non-domain line → anything.
        guard var sense = preferredLine
            ?? lines.first(where: { $0.firstMatch(of: posMarker) != nil })
            ?? lines.first(where: { !$0.hasPrefix("[") })
            ?? lines.first
        else { return "" }

        if let m = sense.firstMatch(of: posMarker) {
            sense.removeSubrange(m.range)
        }

        // Keep only the first few senses (split on Chinese/ASCII commas and "、").
        let senses = sense
            .split(whereSeparator: { ",，、".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return senses.prefix(max(1, maxSenses)).joined(separator: ", ")
    }

    /// Leading ECDICT marker on `line` ("vt", "n", …), lowercased, without the dot.
    private static func ecdictMarker(in line: String) -> String? {
        let marker = #/^[a-zA-Z]{1,5}\./#
        guard let m = line.firstMatch(of: marker) else { return nil }
        return String(m.0.dropLast()).lowercased()
    }

    /// Widest rendered line of `text` (text may contain explicit newlines and mixed
    /// fonts), in points.
    static func maxLineWidth(of text: NSAttributedString) -> CGFloat {
        var widest: CGFloat = 0
        let ns = text.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byLines) { _, range, _, _ in
            widest = max(widest, text.attributedSubstring(from: range).size().width)
        }
        return ceil(widest) + 1   // +1 guards against sub-pixel clipping
    }
}

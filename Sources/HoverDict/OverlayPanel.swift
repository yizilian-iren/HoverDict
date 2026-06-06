import AppKit
import AVFoundation

/// The hover popup: a compact, non-activating, pass-through floating panel showing ONLY
/// the (collapsed) Chinese translation — no English headword, no phonetic. The word is
/// auto-spoken when the popup appears. The panel ignores the mouse entirely, and the
/// pipeline dismisses it as soon as the cursor moves over it.
final class OverlayPanel: NSPanel {

    private let translationLabel = NSTextField(wrappingLabelWithString: "")
    // Must be retained for the lifetime of speech, otherwise it deallocates mid-utterance.
    private let synthesizer = AVSpeechSynthesizer()

    /// The English word to pronounce (what's actually under the cursor).
    private(set) var spokenWord: String = ""
    /// Tracks the currently displayed word so we auto-speak only when it CHANGES,
    /// not every time the pipeline re-fires on the same word.
    private var lastShownWord: String?
    /// Pending auto-speak; cancelled if the cursor moves to another word first.
    private var speakTimer: Timer?
    /// Dwell time on a word before auto-speaking, to avoid blasting audio while the
    /// cursor sweeps across text.
    private let speakDelay: TimeInterval = 0.5

    /// Background translucency (0 = invisible, 1 = opaque). Text stays fully opaque.
    private let backgroundAlpha: CGFloat = 0.8

    /// The popup width adapts to the text, between these bounds; only past the max does
    /// the translation wrap onto more lines.
    private let minContentWidth: CGFloat = 90
    private let maxContentWidth: CGFloat = 360
    private let hMargin: CGFloat = 12
    private let vMargin: CGFloat = 10

    /// How many POS lines of the ECDICT translation to keep when collapsing.
    private let maxPosLines = 2

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
        level = .floating
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        buildContentView()
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
    /// result (may be nil). Auto-speaks when the word changes.
    func show(word: String, entry: DictionaryEntry?, below cursorGlobal: CGPoint) {
        spokenWord = word

        if let translation = entry?.translation {
            translationLabel.stringValue = Self.collapse(translation, maxLines: maxPosLines)
        } else {
            translationLabel.stringValue = "（未找到释义）"
        }

        // Auto-speak only when moving onto a NEW word, AND only after the cursor has
        // dwelled on it for `speakDelay`. Sweeping across many words keeps cancelling
        // the pending timer, so only a word you actually pause on gets spoken — this
        // is what keeps it from being noisy.
        if word.caseInsensitiveCompare(lastShownWord ?? "") != .orderedSame {
            lastShownWord = word
            scheduleAutoSpeak(word)
        }

        // Adaptive width: fit the text up to maxContentWidth; only past that does it wrap.
        let textWidth = Self.maxLineWidth(of: translationLabel.stringValue,
                                          font: translationLabel.font ?? .systemFont(ofSize: 13))
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
        orderFrontRegardless()
    }

    func hidePanel() {
        orderOut(nil)
        // Reset so moving away and back onto the same word speaks again.
        lastShownWord = nil
        speakTimer?.invalidate()
    }

    /// Speak `word` after `speakDelay`, cancelling any earlier pending speech. Fast
    /// sweeps keep rescheduling, so only a word the cursor lingers on is spoken.
    private func scheduleAutoSpeak(_ word: String) {
        speakTimer?.invalidate()
        speakTimer = Timer.scheduledTimer(withTimeInterval: speakDelay, repeats: false) { [weak self] _ in
            self?.speak(word)
        }
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    /// Collapse an ECDICT translation (POS lines separated by "\n") down to the first
    /// `maxLines` non-empty senses, joined back with newlines. The label additionally
    /// caps the rendered height via `maximumNumberOfLines`.
    static func collapse(_ translation: String, maxLines: Int) -> String {
        let lines = translation
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    /// Widest rendered line of `text` (text may contain explicit newlines), in points.
    static func maxLineWidth(of text: String, font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var widest: CGFloat = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let w = (String(line) as NSString).size(withAttributes: attrs).width
            widest = max(widest, w)
        }
        return ceil(widest) + 1   // +1 guards against sub-pixel clipping
    }
}

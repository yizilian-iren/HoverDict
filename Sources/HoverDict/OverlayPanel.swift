import AppKit
import AVFoundation

/// The hover popup: a compact, non-activating floating panel that shows ONLY the
/// (collapsed) Chinese translation — no English headword, no phonetic — plus a small
/// speaker icon for replay. The word is auto-spoken when the popup appears.
/// It never takes key/main status, so the app being read keeps focus.
final class OverlayPanel: NSPanel {

    private let translationLabel = NSTextField(wrappingLabelWithString: "")
    private let speakButton = NSButton()
    // Must be retained for the lifetime of speech, otherwise it deallocates mid-utterance.
    private let synthesizer = AVSpeechSynthesizer()

    /// The English word to pronounce (what's actually under the cursor).
    private(set) var spokenWord: String = ""
    /// Tracks the currently displayed word so we auto-speak only when it CHANGES,
    /// not every time the pipeline re-fires on the same word.
    private var lastShownWord: String?

    /// Fixed content width; the popup grows vertically to fit the translation.
    private let contentWidth: CGFloat = 260
    private let hMargin: CGFloat = 12
    private let vMargin: CGFloat = 10

    /// How many POS lines of the ECDICT translation to keep when collapsing.
    private let maxPosLines = 2

    private var container: NSView!

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 60),
            // .nonactivatingPanel: clicking the speak button works WITHOUT activating
            // our app (so we never steal focus). .borderless: clean tooltip look.
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        buildContentView()
    }

    // Borderless panels normally can't become key; allow it only so the button stays
    // clickable, but we never call makeKey, so focus is preserved.
    override var canBecomeKey: Bool { true }

    private func buildContentView() {
        container = NSView()

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        // Small speaker icon on the left for manual replay.
        speakButton.title = "🔊"
        speakButton.isBordered = false
        speakButton.font = .systemFont(ofSize: 13)
        speakButton.target = self
        speakButton.action = #selector(speakTapped)
        speakButton.translatesAutoresizingMaskIntoConstraints = false
        speakButton.setContentHuggingPriority(.required, for: .horizontal)

        // Chinese translation fills the rest.
        translationLabel.font = .systemFont(ofSize: 13)
        translationLabel.textColor = .labelColor
        translationLabel.maximumNumberOfLines = 3      // collapse: cap the box height
        translationLabel.lineBreakMode = .byTruncatingTail
        translationLabel.preferredMaxLayoutWidth = contentWidth - hMargin * 2 - 26
        translationLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(effect)
        container.addSubview(speakButton)
        container.addSubview(translationLabel)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: contentWidth),

            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            speakButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: hMargin),
            speakButton.topAnchor.constraint(equalTo: container.topAnchor, constant: vMargin),

            translationLabel.leadingAnchor.constraint(equalTo: speakButton.trailingAnchor, constant: 6),
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

        // Auto-speak only when moving onto a NEW word.
        if word.caseInsensitiveCompare(lastShownWord ?? "") != .orderedSame {
            speak(word)
            lastShownWord = word
        }

        // Size the window to fit the content (fixed width, dynamic height).
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        let panelWidth = contentWidth
        let panelHeight = max(fitting.height, 38)

        // Place below the cursor; setFrameOrigin uses the SAME global bottom-left space
        // as NSEvent.mouseLocation, so no conversion is needed.
        let gap: CGFloat = 18
        var origin = CGPoint(x: cursorGlobal.x - 16,
                             y: cursorGlobal.y - gap - panelHeight)

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorGlobal) }) {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - panelWidth - 4)
            // No room below → flip above the cursor.
            if origin.y < f.minY + 4 {
                origin.y = cursorGlobal.y + gap
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
    }

    @objc private func speakTapped() {
        speak(spokenWord)
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
}

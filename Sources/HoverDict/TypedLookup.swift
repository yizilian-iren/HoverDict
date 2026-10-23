import Foundation
import NaturalLanguage

/// What the typed-lookup window (⌥Z) works with: which of 中 / 日 / 英 the input is.
enum TypedLanguage: String, CaseIterable {
    case en, ja, zh

    /// Locale identifier for the Translation framework.
    var localeID: String {
        switch self {
        case .en: "en"
        case .ja: "ja"
        case .zh: "zh-Hans"
        }
    }

    /// Google TTS `tl` code (TTSPlayer) and the system voice to fall back to.
    var ttsCode: String {
        switch self {
        case .en: "en"
        case .ja: "ja"
        case .zh: "zh-CN"
        }
    }
    var voiceID: String {
        switch self {
        case .en: "en-US"
        case .ja: "ja-JP"
        case .zh: "zh-CN"
        }
    }

    /// Display order in the window: Chinese first for a Chinese reader.
    static let displayOrder: [TypedLanguage] = [.zh, .ja, .en]

    var name: String {
        switch self {
        case .en: "英"
        case .ja: "日"
        case .zh: "中"
        }
    }

    /// Kana → Japanese; Han only → Chinese unless NaturalLanguage is sure it's Japanese
    /// (機械学習 reads the same either way, and the translators handle both); else English.
    static func detect(_ text: String) -> TypedLanguage {
        if JapaneseText.containsKana(text) { return .ja }
        guard JapaneseText.containsKanji(text) else { return .en }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .japanese]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        if let ja = hypotheses[.japanese], ja > 0.8 { return .ja }
        return .zh
    }
}

/// One sense of Claude's answer, for its own line on the card: the name, and the
/// explanation it had in brackets ("LoRA（低秩适配）" → "LoRA", "低秩适配").
struct Sense: Equatable {
    var word: String
    var gloss: String?

    /// Claude joins the senses with "；" (sometimes ";").
    static func split(_ text: String) -> [Sense] {
        text.split(whereSeparator: { $0 == "；" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(parse)
    }

    /// A trailing bracket is the gloss; a bracket in the middle is part of the name.
    private static func parse(_ sense: String) -> Sense {
        guard let close = sense.last, close == "）" || close == ")",
              let open = sense.lastIndex(where: { $0 == "（" || $0 == "(" }),
              open != sense.startIndex else { return Sense(word: sense, gloss: nil) }
        let word = sense[..<open].trimmingCharacters(in: .whitespaces)
        let gloss = sense[sense.index(after: open)..<sense.index(before: sense.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !gloss.isEmpty else { return Sense(word: sense, gloss: nil) }
        return Sense(word: word, gloss: gloss)
    }
}

import Foundation
import CoreGraphics

/// Decides whether a hit should be ignored (no popup, no TTS).
///
/// Skips:
///   • numeric tokens (123, 3.14, 50%, $12, 1st, 2024-08-20, 16:9, …)
///   • closed-class / ultra-basic words (the, is, and, of, …)
///   • AI thinking / tool-call status lines ("Thinking…", "Thought for 5s") — only as a
///     short isolated label; the same words inside a sentence are looked up
///   • UI chrome — isolated short labels made of elementary button words ("Send", "OK")
///   • CJK tokens on the English path (Chinese / Japanese text — Japanese has its own path)
///
/// Everything here errs toward showing the popup: a word the reader may not know must
/// never be swallowed, so the word lists hold only words nobody needs translated.
enum LookupFilter {

    /// `fromClick` is stricter: an isolated ALL-CAPS / Title-Case label is treated as a
    /// control, because the user is usually pressing the button, not asking for a
    /// definition. On hover, casing alone never hides a word (headings, table headers).
    static func shouldSkip(_ hit: WordHit, in words: [WordHit], fromClick: Bool) -> Bool {
        let token = normalize(hit.text)
        if token.isEmpty { return true }
        if !token.contains(where: \.isLetter) { return true }   // digits / punctuation only
        // No Latin letters → Chinese/Japanese text, not an English word.
        if !token.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) { return true }
        if isNumericToken(token) { return true }
        let lower = token.lowercased()
        if alwaysSkip.contains(lower) { return true }
        // Isolated icon letters (X close, Q search) and single-letter words (a / I).
        if token.filter(\.isLetter).count == 1 { return true }
        return isUIChrome(hit, in: words, fromClick: fromClick)
    }

    // MARK: - Japanese

    /// True for particles, auxiliaries and lone kana — noise for a Japanese hover
    /// dictionary (は would otherwise resolve to 葉/歯).
    static func shouldSkipJapanese(_ term: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard JapaneseText.isAllHiragana(t) else { return false }
        return t.count == 1 || japaneseFunctionWords.contains(t)
    }

    private static let japaneseFunctionWords: Set<String> = [
        // Particles
        "から", "まで", "より", "ので", "のに", "けど", "けれど", "けれども",
        "ながら", "たり", "だり", "など", "なら", "って", "とか", "だけ", "しか",
        "ばかり", "ほど", "くらい", "ぐらい", "でも", "では", "には", "とは",
        "への", "での", "との", "からの", "までの", "ね", "よね", "かな",
        // Copula / auxiliaries
        "です", "でした", "でしょう", "だった", "だろう", "である",
        "ます", "ました", "ません", "ましょう", "ない", "なかった",
        "たい", "られる", "れる", "せる", "させる",
        // Very common function-like verbs / nouns
        "する", "した", "して", "します", "しました", "いる", "いた", "います",
        "ある", "あった", "あります", "なる", "なった", "こと", "もの", "ため",
        "この", "その", "あの", "どの", "これ", "それ", "あれ", "どれ",
        "ここ", "そこ", "あそこ", "よう", "そう",
    ]

    // MARK: - Numbers

    /// True when `raw` is a number (or number-like), not an English word.
    static func isNumericToken(_ raw: String) -> Bool {
        let s = normalize(raw)
        guard !s.isEmpty else { return false }

        let lower = s.lowercased()
        // 1st / 2nd / 3rd / 4th / 21st …
        if lower.wholeMatch(of: #/^\d+(st|nd|rd|th)$/#) != nil { return true }

        var hasDigit = false
        // Allowed decoration around digits: separators, signs, currency, units.
        let extra = CharacterSet(charactersIn: ".,:%/+-–—−_~$€£¥₹#xX×*")
        for ch in s.unicodeScalars {
            if CharacterSet.decimalDigits.contains(ch) {
                hasDigit = true
                continue
            }
            if extra.contains(ch) { continue }
            return false
        }
        return hasDigit
    }

    // MARK: - Buttons / chrome

    /// Isolated 1–3 word cluster with no nearby prose — typical of a button, tab, or
    /// toolbar item. Dense sentence text (neighbors on the same line) is never skipped.
    private static func isUIChrome(_ target: WordHit,
                                   in words: [WordHit],
                                   fromClick: Bool) -> Bool {
        let lineSlop: CGFloat = 8
        let joinGap: CGFloat = 18   // words closer than this belong to one label
        let proseGap: CGFloat = 36  // farther than this is a separate control

        let sameLine = words
            .filter { abs($0.globalRect.midY - target.globalRect.midY) <= lineSlop }
            .sorted { $0.globalRect.minX < $1.globalRect.minX }

        guard let idx = sameLine.firstIndex(where: {
            $0.text == target.text
                && abs($0.globalRect.midX - target.globalRect.midX) < 0.5
                && abs($0.globalRect.midY - target.globalRect.midY) < 0.5
        }) else {
            return looksLikeChromeWord(target.text, fromClick: fromClick)
        }

        var start = idx
        var end = idx
        while start > 0 {
            let gap = sameLine[start].globalRect.minX - sameLine[start - 1].globalRect.maxX
            if gap > joinGap { break }
            start -= 1
        }
        while end < sameLine.count - 1 {
            let gap = sameLine[end + 1].globalRect.minX - sameLine[end].globalRect.maxX
            if gap > joinGap { break }
            end += 1
        }
        let cluster = Array(sameLine[start...end])

        let hasNearbyProse = sameLine.enumerated().contains { i, hit in
            if i >= start && i <= end { return false }
            let gap: CGFloat
            if i < start {
                gap = sameLine[start].globalRect.minX - hit.globalRect.maxX
            } else {
                gap = hit.globalRect.minX - sameLine[end].globalRect.maxX
            }
            return gap <= proseGap
        }
        // Part of a sentence / paragraph line — look it up.
        if hasNearbyProse { return false }

        // "Thinking…" / "Thought for 5s" / "Searching the web": a short isolated line
        // that STARTS with a status word. Hovering any word of it is noise.
        if cluster.count <= 4, let first = cluster.first,
           statusWords.contains(normalize(first.text).lowercased()) {
            return true
        }

        guard cluster.count <= 3 else { return false }
        let letterCount = cluster.map(\.text).joined().filter(\.isLetter).count
        guard letterCount <= 22 else { return false }

        if cluster.contains(where: { uiLabels.contains(normalize($0.text).lowercased()) }) {
            return true
        }
        // Clicking an isolated ALL-CAPS / Title-Case label (Bold, New Chat, README) is a
        // button press. Hovering one is not skipped: it may be a heading.
        if fromClick && cluster.allSatisfy({ isTitleCaseWord($0.text) || isAllCapsWord($0.text) }) {
            return true
        }
        return false
    }

    private static func looksLikeChromeWord(_ raw: String, fromClick: Bool) -> Bool {
        let lower = normalize(raw).lowercased()
        if uiLabels.contains(lower) || statusWords.contains(lower) { return true }
        if fromClick && (isTitleCaseWord(raw) || isAllCapsWord(raw)) { return true }
        return false
    }

    private static func isAllCapsWord(_ raw: String) -> Bool {
        let letters = normalize(raw).filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    private static func isTitleCaseWord(_ raw: String) -> Bool {
        let t = normalize(raw)
        guard let first = t.first, first.isLetter, first.isUppercase else { return false }
        let rest = t.dropFirst()
        return rest.contains(where: \.isLetter) && rest.filter(\.isLetter).allSatisfy(\.isLowercase)
            || rest.filter(\.isLetter).isEmpty && t.count >= 2
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    /// AI thinking / tool-call indicators (Claude, Cursor, ChatGPT, …). Skipped only when
    /// one starts a short isolated line — in a sentence "reasoning" is a real word.
    private static let statusWords: Set<String> = [
        "thinking", "thought", "thoughts",
        "running", "reasoning",
        "generating", "streaming",
        "analyzing", "analysing", "considering",
        "working", "loading", "waiting",
        "researching", "searching",
    ]

    /// Always skipped, even inside a sentence: function words and a handful of
    /// ultra-basic tokens that are noise for a hover dictionary.
    private static let alwaysSkip: Set<String> = [
        // Articles, pronouns
        "a", "an", "the",
        "i", "me", "my", "mine", "myself",
        "you", "your", "yours", "yourself", "yourselves",
        "he", "him", "his", "himself",
        "she", "her", "hers", "herself",
        "it", "its", "itself",
        "we", "us", "our", "ours", "ourselves",
        "they", "them", "their", "theirs", "themselves",
        "this", "that", "these", "those",
        "who", "whom", "whose", "which", "what",
        "where", "when", "why", "how",
        // Be / do / have + modals
        "is", "am", "are", "was", "were", "be", "been", "being",
        "do", "does", "did", "doing", "done",
        "have", "has", "had", "having",
        "will", "would", "can", "could", "shall", "should",
        "may", "might", "must",
        // Prepositions, conjunctions, particles
        "of", "to", "in", "on", "at", "for", "with", "from", "by",
        "as", "about", "into", "through", "during", "before", "after",
        "above", "below", "between", "under", "out", "up", "down",
        "off", "over", "again", "further", "then", "once",
        "and", "but", "or", "nor", "so", "yet",
        "if", "because", "while", "although", "though", "unless",
        "until", "whether",
        "not", "no", "yes", "ok", "okay",
        "there", "here", "now",
        "all", "each", "every", "both", "few", "more", "most",
        "other", "some", "any", "such",
        "only", "own", "same", "than", "too", "very",
        "just", "also", "even", "still", "already",
        // Ultra-basic content
        "get", "got", "gets", "getting",
        "go", "goes", "going", "went", "gone",
        "come", "comes", "coming", "came",
        "good", "bad", "big", "small",
        "one", "two", "three",
    ]

    /// Standalone control labels. Only applied to *isolated* clusters, so "send" in
    /// "please send it" still looks up. Elementary words only: anything a learner might
    /// want translated (dismiss, discard, snooze, …) stays out, even though it is a
    /// common button.
    private static let uiLabels: Set<String> = [
        "ok", "okay", "cancel", "save", "delete", "send", "close", "next", "back",
        "done", "open", "new", "edit", "copy", "paste", "cut", "search", "settings",
        "help", "share", "download", "upload", "skip", "later",
        "yes", "no", "more", "add", "start", "stop", "play",
        "login", "logout", "signin", "signout", "signup",
        "quit", "exit", "print", "got", "thanks", "home",
    ]
}

import Foundation

/// One numbered sense of an Oxford entry: the Chinese translation plus the editors'
/// hint about WHICH meaning it is, e.g. label "(reject)", translation "对…不予考虑".
struct OxfordSense: Equatable {
    /// Subject field and/or sense indicator and/or gloss: "Physics (force)", "(reject)",
    /// "[尤指白天的]". nil when the entry gives none.
    let label: String?
    let translation: String
}

/// The senses listed under one part of speech ("A. transitive verb …").
struct OxfordGroup: Equatable {
    let pos: SensePicker.POSKind
    let senses: [OxfordSense]
}

/// A parsed entry: headword + its part-of-speech groups, in dictionary order.
struct OxfordEntry: Equatable {
    let headword: String
    let groups: [OxfordGroup]
}

/// English→Chinese lookups against macOS's built-in 牛津英汉汉英词典
/// ("Simplified Chinese - English" in Dictionary.app). Its entries are written by
/// lexicographers and label each sense, so they read far better than ECDICT's merged
/// synonym lists — but it has fewer headwords (no "idempotent"), so ECDICT stays as the
/// fallback for whatever this returns nil for.
final class OxfordDictionary {

    private let system: SystemDictionary
    private let queue = DispatchQueue(label: "com.hoverdict.oxford")

    /// Senses kept for the popup.
    private let maxSenses = 3

    init?() {
        guard let system = SystemDictionary(bundleName: "Simplified Chinese - English.dictionary") else {
            return nil
        }
        self.system = system
    }

    /// The senses to show for `rawWord`, preferring the part of speech the context
    /// suggests. nil when the dictionary has nothing usable. Call off the main thread.
    func lookup(_ rawWord: String, preferredPOS: SensePicker.POSKind?) -> [OxfordSense]? {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !word.isEmpty else { return nil }

        return queue.sync {
            let key = CacheKey(word: word, pos: preferredPOS)
            if let cached = cache[key] { return cached.senses }

            var group = pickedGroup(for: word, preferredPOS: preferredPOS)
            // The index misses some irregular forms (mice); retry with NLTagger's lemma.
            if group == nil {
                let lemma = DictionaryService.lemmatize(word)
                if lemma.caseInsensitiveCompare(word) != .orderedSame {
                    group = pickedGroup(for: lemma, preferredPOS: preferredPOS)
                }
            }
            let senses = group.map { Array($0.senses.prefix(maxSenses)) }
            // Big entries (run, go, set) take ~100ms to parse, and hovering re-fires on
            // the same word; misses are cached too.
            if cache.count >= 500 { cache.removeAll() }
            cache[key] = CachedLookup(senses: senses)
            return senses
        }
    }

    private struct CacheKey: Hashable {
        let word: String
        let pos: SensePicker.POSKind?
    }
    private struct CachedLookup {
        let senses: [OxfordSense]?
    }
    private var cache: [CacheKey: CachedLookup] = [:]

    private func pickedGroup(for word: String, preferredPOS: SensePicker.POSKind?) -> OxfordGroup? {
        let entries = system.entriesHTML(for: word).compactMap(Self.parse(html:))
        return Self.pick(from: entries, for: word, preferredPOS: preferredPOS)
    }

    /// ALL-CAPS tokens are almost always acronyms, where this dictionary is thin and
    /// often off-topic for technical text (API → 空气污染指数). ECDICT goes first for
    /// those; Oxford is only the fallback.
    static func prefersECDICT(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        return letters.count >= 2 && letters.allSatisfy(\.isUppercase)
    }

    // MARK: - Choosing the entry

    /// The dictionary's index returns every entry a form could belong to, related or not:
    /// "running" → run, running; "better" → better, bettor, good, well. Keep the entries
    /// for the word itself, then those it is an inflection of; within that order take the
    /// first group matching `preferredPOS` ("he was running" → the verb group of "run",
    /// not the adjective "running"), else simply the first group.
    static func pick(from entries: [OxfordEntry],
                     for word: String,
                     preferredPOS: SensePicker.POSKind?) -> OxfordGroup? {
        func isExact(_ entry: OxfordEntry) -> Bool {
            entry.headword.caseInsensitiveCompare(word) == .orderedSame
        }
        let lemma = DictionaryService.lemmatize(word)
        let candidates = entries.filter(isExact)
            + entries.filter { !isExact($0) && isBaseForm($0.headword, of: word, lemma: lemma) }

        if let preferredPOS, preferredPOS != .other {
            for entry in candidates {
                if let group = entry.groups.first(where: { $0.pos == preferredPOS }) { return group }
            }
        }
        return candidates.first?.groups.first
    }

    /// True when `headword` plausibly is what `word` inflects from: the lemma NLTagger
    /// gives (went → go), or the word starts with the headword minus an ending that
    /// inflection replaces (harden|ed, mak·e|ing, carr·y|ied, lea·f|ves, analys·is|es).
    /// This rules out look-alikes the index also returns (better → bett·or).
    static func isBaseForm(_ headword: String, of word: String, lemma: String) -> Bool {
        let head = headword.lowercased()
        let w = word.lowercased()
        if head == lemma.lowercased() { return true }
        let shared = zip(head, w).prefix { $0 == $1 }.count
        guard shared >= 2 else { return false }
        return replaceableEndings.contains(String(head.dropFirst(shared)))
    }

    private static let replaceableEndings: Set<String> = ["", "e", "y", "f", "fe", "is", "um", "us", "on"]

    // MARK: - Parsing

    /// Entry XHTML layout (Oxford Chinese Dictionary):
    ///   entry @d:title          → headword
    ///   span.gramb.x_xd0        → one part-of-speech group; span.ps holds its name
    ///   span.semb.x_xd1         → one numbered sense, holding span.trg (or several
    ///                             inside span.trgg), each with:
    ///       span.fld            → subject field ("Physics")
    ///       span.ind            → sense indicator ("(force)")
    ///       span.gl             → gloss ("[尤指白天的]")
    ///       span.trans          → the Chinese (pinyin is `trans ty_pinyin`)
    ///   Collocates (span.co), examples (span.exg), register (span.lev) and phrasal
    ///   verbs / idioms (x_xo… blocks) are all skipped.
    static func parse(html: String) -> OxfordEntry? {
        guard let doc = try? XMLDocument(xmlString: html, options: []) else { return nil }

        func cls(_ token: String) -> String {
            "contains(concat(' ', normalize-space(@class), ' '), ' \(token) ')"
        }
        func nodes(_ xpath: String, in node: XMLNode) -> [XMLNode] {
            (try? node.nodes(forXPath: xpath)) ?? []
        }
        func text(_ node: XMLNode) -> String {
            (node.stringValue ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        func sense(from semb: XMLNode) -> OxfordSense? {
            let targets = nodes("./span[\(cls("trg"))] | ./span[\(cls("trgg"))]/span[\(cls("trg"))]", in: semb)
            let chinese = "./span[\(cls("trans")) and not(\(cls("ty_pinyin")))]"
            let translations = targets.compactMap { nodes(chinese, in: $0).first.map(text) }
                .filter { !$0.isEmpty }
            guard let first = targets.first, !translations.isEmpty else { return nil }

            let fields = nodes("./span[\(cls("fld"))]", in: first)
                .map { text($0).trimmingCharacters(in: CharacterSet(charactersIn: ", ")) }
                .filter { !$0.isEmpty }
            var label: [String] = []
            if !fields.isEmpty { label.append(fields.joined(separator: ", ")) }
            label += nodes("./span[\(cls("ind"))] | ./span[\(cls("gl"))]", in: first).map(text)
            label = label.filter { !$0.isEmpty }

            return OxfordSense(label: label.isEmpty ? nil : label.joined(separator: " "),
                               translation: translations.prefix(2).joined(separator: "、"))
        }

        let title = nodes("//*[local-name()='entry']/@*[local-name()='title']", in: doc).first.map(text)
        guard let headword = title, !headword.isEmpty else { return nil }

        var groups: [OxfordGroup] = []
        for gramb in nodes("//span[\(cls("gramb")) and \(cls("x_xd0"))]", in: doc) {
            let senses = nodes("./span[\(cls("semb")) and \(cls("x_xd1"))]", in: gramb).compactMap(sense)
            guard !senses.isEmpty else { continue }
            let pos = nodes(".//span[\(cls("ps"))]", in: gramb).first.map(text) ?? ""
            groups.append(OxfordGroup(pos: posKind(pos), senses: senses))
        }
        // A cross-reference stub ("better → see good") has no senses of its own.
        return groups.isEmpty ? nil : OxfordEntry(headword: headword, groups: groups)
    }

    /// Oxford's part-of-speech names → our coarse classes.
    static func posKind(_ name: String) -> SensePicker.POSKind {
        let n = name.lowercased()
        // "adverb" contains "verb" — test it first.
        if n.contains("adverb") { return .adverb }
        if n.contains("verb") { return .verb }
        if n.contains("noun") && !n.contains("pronoun") { return .noun }
        if n.contains("adjective") { return .adjective }
        if n.contains("preposition") { return .preposition }
        if n.contains("conjunction") { return .conjunction }
        if n.contains("pronoun") { return .pronoun }
        if n.contains("determiner") || n.contains("article") { return .determiner }
        if n.contains("number") || n.contains("numeral") { return .number }
        return .other
    }
}

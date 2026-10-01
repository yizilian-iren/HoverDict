import Foundation
import CoreServices

/// A Japanese→Chinese lookup result.
struct JapaneseEntry {
    let surface: String    // text under the cursor, e.g. 食べました
    let headword: String   // dictionary form, e.g. 食べる
    let reading: String?   // hiragana, e.g. たべる — nil when the headword is already all kana
    let senses: [String]   // Chinese meanings, one string per sense, e.g. ["吃", "生活"]
}

/// Japanese→Chinese lookups against macOS's built-in 小学館「日中・中日辞典」
/// ("Simplified Chinese - Japanese" in Dictionary.app), so no extra download is bundled.
///
/// Segmentation + conjugation come for free from DictionaryServices:
///   • `DCSGetTermRangeInString` (public) finds the dictionary term at a character offset
///     in an OCR'd line — no spaces needed, and 食べました is taken as one term.
///   • `DCSCopyRecordsForSearchString` (private) maps that surface form back to its
///     entries (食べました → 食べる【たべる】) and gives us structured XHTML to parse.
/// Both go through `SystemDictionary`; if the dictionary isn't installed (or the private
/// API is gone) the initializer fails and Japanese take-word is disabled.
final class JapaneseDictionary {

    private let system: SystemDictionary
    private var dictionary: DCSDictionary { system.dictionary }
    private let queue = DispatchQueue(label: "com.hoverdict.japanese")

    /// Senses kept for the popup, and Chinese words kept per sense.
    private let maxSenses = 2
    private let maxWordsPerSense = 3

    init?() {
        guard let system = SystemDictionary(bundleName: "Simplified Chinese - Japanese.dictionary") else {
            return nil
        }
        self.system = system
    }

    // MARK: - Lookup

    /// Look up the term covering `utf16Offset` in `line`. Returns nil for particles /
    /// auxiliaries, non-Japanese text, or no dictionary entry. Call off the main thread.
    func lookup(line: String, utf16Offset: Int) -> JapaneseEntry? {
        queue.sync {
            let ns = line as NSString
            guard utf16Offset >= 0, utf16Offset < ns.length else { return nil }

            // Katakana loanwords: the contiguous katakana run is the word, and the
            // dictionary may spell it with or without a final ー (ソファ / ソファー).
            if let run = JapaneseText.katakanaRun(in: ns, at: utf16Offset) {
                var candidates = [run]
                if run.hasSuffix("ー") { candidates.append(String(run.dropLast())) } else { candidates.append(run + "ー") }
                for candidate in candidates {
                    if let html = bestRecordHTML(for: candidate) {
                        return Self.parse(html: html, surface: candidate,
                                          maxSenses: maxSenses, maxWordsPerSense: maxWordsPerSense)
                    }
                }
            }

            guard let range = termRange(in: line, covering: utf16Offset) else { return nil }
            let surface = ns.substring(with: NSRange(location: range.location, length: range.length))
            guard JapaneseText.containsJapanese(surface),
                  !LookupFilter.shouldSkipJapanese(surface) else { return nil }
            // All-hiragana right after kanji is okurigana / an auxiliary hanging off the
            // previous word (勉強|している would otherwise resolve to 子弟).
            if JapaneseText.isAllHiragana(surface), range.location > 0,
               let prev = Unicode.Scalar(ns.character(at: range.location - 1)),
               JapaneseText.isKanji(prev) {
                return nil
            }

            guard let html = bestRecordHTML(for: surface) else { return nil }
            return Self.parse(html: html,
                              surface: surface,
                              maxSenses: maxSenses,
                              maxWordsPerSense: maxWordsPerSense)
        }
    }

    /// `DCSGetTermRangeInString` treats the offset like a caret *between* characters and,
    /// at a word boundary, returns the term on the left (offset of 雨 in 明日は雨 → は).
    /// Retry one to the right, and only accept a range that covers the character.
    private func termRange(in line: String, covering offset: Int) -> CFRange? {
        for probe in [offset, offset + 1] where probe <= (line as NSString).length {
            let r = DCSGetTermRangeInString(dictionary, line as CFString, probe)
            if r.location != kCFNotFound, r.length > 0,
               r.location <= offset, offset < r.location + r.length {
                return r
            }
        }
        return nil
    }

    /// The dictionary is bidirectional: `j_…` entries are Japanese headwords, `z_…` are
    /// Chinese characters (猫 máo). Keep only Japanese ones; among several, pick the one
    /// whose title shares the longest prefix with the surface (降るでしょう → 降る, not
    /// 下る which merely lists 降る as a spelling), then by any other spelling
    /// (日本語 → the 日本 entry holding 日本語). Ties keep dictionary order.
    private func bestRecordHTML(for surface: String) -> String? {
        var best: (html: String, title: Int, any: Int)?
        for html in system.entriesHTML(for: surface) {
            guard html.contains("d:entry id=\"j_") else { continue }
            let spellings = Self.spellings(in: html)
            let title = spellings.first.map { Self.commonPrefixLength($0, surface) } ?? 0
            let any = spellings.map { Self.commonPrefixLength($0, surface) }.max() ?? 0
            if best == nil || (title, any) > (best!.title, best!.any) {
                best = (html, title, any)
            }
        }
        return best?.html
    }

    /// d:title plus every 【…】 kanji spelling and compound spelling (span.cv), cheaply
    /// scraped without a full parse.
    private static func spellings(in html: String) -> [String] {
        var result: [String] = []
        if let r = html.range(of: #"d:title="[^"]*""#, options: .regularExpression) {
            result.append(String(html[r].dropFirst(9).dropLast()))
        }
        var searchStart = html.startIndex
        let pattern = #"class="(?:hv|cv)[^"]*">[^<]*<"#
        while let r = html.range(of: pattern, options: .regularExpression, range: searchStart..<html.endIndex) {
            let chunk = html[r]
            if let gt = chunk.firstIndex(of: ">") {
                result.append(String(chunk[chunk.index(after: gt)...].dropLast()))
            }
            searchStart = r.upperBound
        }
        return result
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    // MARK: - Parsing

    /// Entry XHTML layout (小学館 日中):
    ///   span.hw           → reading (kana)
    ///   entry @d:title    → headword (食べる)
    ///   span.semb.x_xd1   → one numbered sense; its direct span.trg children hold
    ///   span.trans[lang=zh-cmn-Hans] → Chinese words (pinyin is `trans ty_pinyin`,
    ///   examples live in span.exg, idioms in span.semb.x_xo2 — all skipped).
    static func parse(html: String,
                      surface: String,
                      maxSenses: Int,
                      maxWordsPerSense: Int) -> JapaneseEntry? {
        guard let doc = try? XMLDocument(xmlString: html, options: []) else { return nil }

        func cls(_ token: String) -> String {
            "contains(concat(' ', normalize-space(@class), ' '), ' \(token) ')"
        }
        func texts(_ xpath: String, in node: XMLNode) -> [String] {
            ((try? node.nodes(forXPath: xpath)) ?? [])
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        let title = texts("//*[local-name()='entry']/@*[local-name()='title']", in: doc).first
        let rawReading = texts("//span[\(cls("hw"))]", in: doc).first
        let kanjiForms = texts("//span[\(cls("hv"))]", in: doc)
        // 寿司 is filed under 鮨【すし】 — show the spelling on screen when it is listed.
        let headword = kanjiForms.contains(surface) ? surface : (title ?? rawReading ?? surface)

        let chinese = "span[@class='trans' and @lang='zh-cmn-Hans']"

        // Compounds are sub-entries (span.csec) inside their head's entry: 日本語 lives in
        // にほん【日本】 as「にほん語・にほんご・日本語 → 日文、日语」. Prefer that block.
        if !surface.contains("'"),
           let compound = try? doc.nodes(forXPath: "//span[\(cls("csec"))][.//span[\(cls("cv"))][normalize-space(.)='\(surface)']]").first {
            var senses: [String] = []
            for node in (try? compound.nodes(forXPath: ".//span[\(cls("semb"))]")) ?? [] {
                let words = texts("./span[\(cls("trg"))]/\(chinese)", in: node)
                if !words.isEmpty {
                    senses.append(words.prefix(maxWordsPerSense).joined(separator: "、"))
                }
                if senses.count == maxSenses { break }
            }
            if !senses.isEmpty {
                let kana = texts(".//span[\(cls("cv"))]", in: compound)
                    .first { !JapaneseText.containsKanji($0) && JapaneseText.containsKana($0) }
                let reading = JapaneseText.containsKanji(surface) ? kana.map(JapaneseText.toHiragana) : nil
                return JapaneseEntry(surface: surface, headword: surface, reading: reading, senses: senses)
            }
        }

        var senses: [String] = []
        let senseNodes = (try? doc.nodes(forXPath: "//span[\(cls("semb")) and \(cls("x_xd1"))]")) ?? []
        for node in senseNodes {
            let words = texts("./span[\(cls("trg"))]/\(chinese)", in: node)
            if !words.isEmpty {
                senses.append(words.prefix(maxWordsPerSense).joined(separator: "、"))
            }
            if senses.count == maxSenses { break }
        }
        // Some short entries have no numbered senses — take top-level translations,
        // still skipping example sentences.
        if senses.isEmpty {
            let words = texts("//span[\(cls("trg"))][not(ancestor::span[\(cls("exg"))])]/\(chinese)", in: doc)
            if !words.isEmpty {
                senses.append(words.prefix(maxWordsPerSense).joined(separator: "、"))
            }
        }

        // Only show a reading when the headword has kanji; normalize ネコ → ねこ.
        var reading: String?
        if let rawReading, JapaneseText.containsKanji(headword) {
            reading = JapaneseText.toHiragana(rawReading)
        }
        return JapaneseEntry(surface: surface, headword: headword, reading: reading, senses: senses)
    }
}

/// Character-class helpers for telling Japanese apart from Chinese / Latin text.
enum JapaneseText {

    static func isKana(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3041...0x309F,   // Hiragana
             0x30A0...0x30FF,   // Katakana (incl. ー)
             0x31F0...0x31FF,   // Katakana phonetic extensions
             0xFF66...0xFF9F:   // Half-width katakana
            return true
        default:
            return false
        }
    }

    static func isKanji(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005:   // + 々
            return true
        default:
            return false
        }
    }

    static func isJapanese(_ c: Character) -> Bool {
        c.unicodeScalars.contains { isKana($0) || isKanji($0) }
    }

    static func containsKana(_ s: String) -> Bool { s.unicodeScalars.contains(where: isKana) }
    static func containsKanji(_ s: String) -> Bool { s.unicodeScalars.contains(where: isKanji) }
    static func containsJapanese(_ s: String) -> Bool { s.contains(where: isJapanese) }

    static func isAllHiragana(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

    static func isKatakana(_ c: unichar) -> Bool {
        (0x30A0...0x30FF).contains(c) || (0x31F0...0x31FF).contains(c)
    }

    /// The maximal run of katakana (incl. ー) around `offset`, if that character is katakana.
    static func katakanaRun(in s: NSString, at offset: Int) -> String? {
        guard offset < s.length, isKatakana(s.character(at: offset)),
              s.character(at: offset) != 0x30FB else { return nil }   // skip ・
        var start = offset
        var end = offset + 1
        while start > 0, isKatakana(s.character(at: start - 1)), s.character(at: start - 1) != 0x30FB { start -= 1 }
        while end < s.length, isKatakana(s.character(at: end)), s.character(at: end) != 0x30FB { end += 1 }
        return s.substring(with: NSRange(location: start, length: end - start))
    }

    /// カタカナ → ひらがな (other characters unchanged).
    static func toHiragana(_ s: String) -> String {
        s.applyingTransform(.hiraganaToKatakana, reverse: true) ?? s
    }
}

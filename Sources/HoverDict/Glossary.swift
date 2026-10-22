import Foundation

/// A flat word list that wins over the dictionaries: the bundled tech glossary
/// (`tech_glossary.txt`, tech sense first — thread → 线程；线) and the user's own
/// `custom.txt`. One entry per line, `word = 释义`; `#` starts a comment.
///
/// All-caps keys (LLM, RAG) match only all-caps words, so the acronym RAG doesn't
/// change the everyday "rag"; other keys match case-insensitively. A word that isn't
/// listed is retried as its lemma (threads → thread).
struct Glossary: Equatable {
    private(set) var exact: [String: String] = [:]
    private(set) var folded: [String: String] = [:]

    var isEmpty: Bool { exact.isEmpty && folded.isEmpty }

    init(text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"),
                  let eq = line.firstIndex(where: { $0 == "=" || $0 == "＝" }) else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            if Self.isAcronym(key) {
                exact[key] = value
            } else {
                folded[key.lowercased()] = value
            }
        }
    }

    init(contentsOf url: URL) {
        self.init(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    func lookup(_ rawWord: String) -> String? {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        guard !word.isEmpty, !isEmpty else { return nil }
        if Self.isAcronym(word) {
            if let hit = exact[word] { return hit }
            // "APIs" → "API".
            if word.hasSuffix("s"), let hit = exact[String(word.dropLast())] { return hit }
        }
        let lower = word.lowercased()
        if let hit = folded[lower] { return hit }
        let lemma = DictionaryService.lemmatize(word).lowercased()
        if lemma != lower, let hit = folded[lemma] { return hit }
        // NLTagger doesn't know every tech word on its own (tokens, embeddings):
        // strip the regular endings too.
        return Self.stems(of: lower).lazy.compactMap { folded[$0] }.first
    }

    /// The other way round, for typed Chinese: 线程 → ["thread"]. A key matches when one
    /// of its `；`-separated meanings, minus （notes）, is exactly `chinese`.
    func reverseLookup(_ chinese: String) -> [String] {
        let target = chinese.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return [] }
        let hits = exact.merging(folded) { a, _ in a }.compactMap { key, value -> String? in
            Self.meanings(of: value).contains(target) ? key : nil
        }
        return hits.sorted()
    }

    /// "分叉（复刻代码库）；叉子" → ["分叉", "叉子"].
    static func meanings(of value: String) -> [String] {
        value.split(whereSeparator: { $0 == "；" || $0 == ";" }).map { part in
            var s = String(part)
            while let open = s.firstIndex(where: { $0 == "（" || $0 == "(" }),
                  let close = s[open...].firstIndex(where: { $0 == "）" || $0 == ")" }) {
                s.removeSubrange(open...close)
            }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// tokens → token, caches → cache, patches → patch, committed → commit,
    /// cached → cache / cach, deploying → deploy, merging → merge.
    static func stems(of word: String) -> [String] {
        var out: [String] = []
        func strip(_ suffix: String, add: [String] = [""]) {
            guard word.hasSuffix(suffix), word.count > suffix.count + 2 else { return }
            let base = String(word.dropLast(suffix.count))
            out += add.map { base + $0 }
            // committed → commit, running → run
            if let last = base.last, base.dropLast().last == last, !"aeiou".contains(last) {
                out.append(String(base.dropLast()))
            }
        }
        strip("ies", add: ["y"])
        strip("es")
        strip("s")
        strip("ed", add: ["", "e"])
        strip("ing", add: ["", "e"])
        return out
    }

    /// "LLM", "GPU", "APIs": two or more letters, all capitals (a trailing plural "s"
    /// allowed). "SaaS" and "MoE" count too: more than one capital, starting with one.
    static func isAcronym(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count >= 2, letters.first?.isUppercase == true else { return false }
        let body = letters.hasSuffix("s") ? letters.dropLast() : Substring(letters)
        return body.filter(\.isUppercase).count >= 2
    }
}

/// The user's own glossary in Application Support, re-read whenever the file changes,
/// so an edit takes effect on the next lookup without restarting.
final class UserGlossary {

    let url: URL
    private var glossary = Glossary(text: "")
    private var loadedDate: Date?
    private let queue = DispatchQueue(label: "com.hoverdict.userglossary")

    init(url: URL = UserGlossary.defaultURL) {
        self.url = url
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoverDict/custom.txt")
    }

    /// Call off the main thread.
    func lookup(_ word: String) -> String? {
        queue.sync {
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if date != loadedDate {
                glossary = date == nil ? Glossary(text: "") : Glossary(contentsOf: url)
                loadedDate = date
            }
            return glossary.lookup(word)
        }
    }

    /// Create the file with instructions the first time, so the menu item has
    /// something to open.
    func ensureExists() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Self.template.write(to: url, atomically: true, encoding: .utf8)
    }

    static let template = """
    # HoverDict 自定义释义:一行一个「词 = 意思」,存盘后下一次取词就生效,不用重启。
    # 这里的词优先于内置科技词表、牛津和 ECDICT。# 开头的行不算。
    # 全大写的词(如 RAG)只匹配全大写;其余不分大小写,复数、过去式等会落到原形。
    # 例:
    # token = 令牌
    # agent = 智能体

    """
}

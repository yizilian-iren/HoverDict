import AppKit

/// One lookup, as kept in the history (I-29): what was looked up, where and when, and the
/// results it got — so opening it again shows them at once without asking Claude.
struct HistoryRecord: Codable, Equatable {
    enum Source: String, Codable {
        /// The ⌥Z window.
        case typed
        /// A word clicked in click mode (hovering isn't recorded).
        case click
    }

    var query: String
    var language: String
    var date: Date
    var source: Source
    /// The app in front when it was looked up (for ⌥Z, the one before the window came up).
    var appName: String?
    var bundleID: String?
    var claude: StoredTranslation?
    /// The dictionary block, or for a click the popup's text, as RTF (it's styled text);
    /// nil = nothing found.
    var dictionaryRTF: Data?
    /// How the Claude request went: TTFB, generation time, tokens (I-30). Not for a lookup
    /// that didn't ask Claude.
    var claudeTiming: ClaudeTiming?

    var key: String { Self.key(query) }
    static func key(_ query: String) -> String { query.lowercased() }

    var typedLanguage: TypedLanguage { TypedLanguage(rawValue: language) ?? .en }

    var dictionary: NSAttributedString? {
        dictionaryRTF.flatMap {
            try? NSAttributedString(data: $0, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                    documentAttributes: nil)
        }
    }

    static func rtf(_ text: NSAttributedString?) -> Data? {
        text.flatMap {
            try? $0.data(from: NSRange(location: 0, length: $0.length),
                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
    }

    /// The first meaning, for the list row: Claude's first Chinese sense (English when the
    /// word is Chinese) that isn't just the word again, else the first line of the dictionary text that isn't the word.
    var summary: String {
        if let claude = claude?.translation {
            let target: TypedLanguage = typedLanguage == .zh ? .en : .zh
            // "LoRA（低秩适配）" for lora says nothing new as "LoRA": take its gloss.
            for sense in Sense.split(claude.text(for: target)) {
                if sense.word.lowercased() != key { return sense.word }
                if let gloss = sense.gloss { return gloss }
            }
        }
        let lines = (dictionary?.string ?? "").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix(key) }
        return lines.first ?? ""
    }
}

/// `ClaudeTranslation` as saved in the history file.
struct StoredTranslation: Codable, Equatable {
    var zh: String
    var ja: String
    var en: String
    var note: String
    /// nil in lines written before I-31.
    var reading: String?
    var model: String

    init(_ translation: ClaudeTranslation) {
        zh = translation.zh
        ja = translation.ja
        en = translation.en
        note = translation.note
        reading = translation.reading.isEmpty ? nil : translation.reading
        model = translation.model.rawValue
    }

    var translation: ClaudeTranslation {
        ClaudeTranslation(zh: zh, ja: ja, en: en, note: note, reading: reading ?? "",
                          model: ClaudeModel(rawValue: model) ?? .sonnet)
    }
}

/// The lookup history and favorites in `~/Library/Application Support/HoverDict/`.
/// Nothing is ever deleted (the user: 「都是数据不要删除就好」): every lookup (⌥Z, and words
/// clicked in click mode) is a line appended to `history.jsonl`; the ⌥Z list shows each
/// typed word once, its latest lookup.
/// 「从列表隐藏」 only marks the word hidden (until it's looked up again); stars and hidden
/// marks live in `marks.json`. A line that can't be read is skipped, never cleaned out.
/// Main thread only.
final class LookupHistory {

    static let defaultDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HoverDict")

    private struct Marks: Codable {
        /// Word key → when it was starred.
        var favorites: [String: Date] = [:]
        /// Word key → when it was hidden; a later lookup shows it again.
        var hidden: [String: Date] = [:]
    }

    /// nil: kept in memory only (the screenshot demo).
    let directory: URL?
    /// Every lookup, oldest first, as in the file.
    private(set) var records: [HistoryRecord] = []
    private var marks = Marks()
    /// marks.json is there but couldn't be read: never overwrite it with what's in memory.
    private var marksUnreadable = false

    private var historyURL: URL? { directory?.appendingPathComponent("history.jsonl") }
    private var marksURL: URL? { directory?.appendingPathComponent("marks.json") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL? = LookupHistory.defaultDirectory) {
        self.directory = directory
        if let historyURL, let data = try? Data(contentsOf: historyURL) {
            records = data.split(separator: UInt8(ascii: "\n")).compactMap {
                try? Self.decoder.decode(HistoryRecord.self, from: Data($0))
            }
        }
        if let marksURL, FileManager.default.fileExists(atPath: marksURL.path) {
            if let data = try? Data(contentsOf: marksURL),
               let saved = try? Self.decoder.decode(Marks.self, from: data) {
                marks = saved
            } else {
                marksUnreadable = true
                NSLog("HoverDict: \(marksURL.path) can't be read; stars and hidden marks won't be saved this launch")
            }
        }
    }

    // MARK: - Reading

    /// The latest ⌥Z lookup of each word, newest first. Clicked words are only kept on
    /// file, not listed (the user's choice, I-29).
    private var latest: [HistoryRecord] {
        var seen = Set<String>()
        return records.reversed().filter { $0.source == .typed && seen.insert($0.key).inserted }
    }

    /// The latest Claude answer saved for a word (an offline lookup after it saved none).
    func savedClaude(_ query: String) -> ClaudeTranslation? {
        let key = HistoryRecord.key(query)
        return records.last { $0.key == key && $0.claude != nil }?.claude?.translation
    }

    func isFavorite(_ query: String) -> Bool { marks.favorites[HistoryRecord.key(query)] != nil }

    /// Starred words, the latest star first.
    var favorites: [HistoryRecord] {
        latest.filter { marks.favorites[$0.key] != nil }
            .sorted { marks.favorites[$0.key]! > marks.favorites[$1.key]! }
    }

    /// The latest `count` words that aren't starred (those have their own group) or hidden.
    func recent(_ count: Int = 10) -> [HistoryRecord] {
        Array(latest.filter { record in
            guard marks.favorites[record.key] == nil else { return false }
            if let hidden = marks.hidden[record.key], hidden >= record.date { return false }
            return true
        }.prefix(count))
    }

    // MARK: - Writing

    func append(_ record: HistoryRecord) {
        records.append(record)
        guard let historyURL, var line = try? Self.encoder.encode(record) else { return }
        line.append(UInt8(ascii: "\n"))
        do {
            try ensureDirectory()
            // Only a missing file is created; one that's there but can't be opened is left
            // alone (writing it anew would leave only this line).
            guard FileManager.default.fileExists(atPath: historyURL.path) else {
                try line.write(to: historyURL, options: .withoutOverwriting)
                return
            }
            let handle = try FileHandle(forWritingTo: historyURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            NSLog("HoverDict: saving history failed: \(error)")
        }
    }

    func setFavorite(_ favorite: Bool, for query: String, date: Date = Date()) {
        marks.favorites[HistoryRecord.key(query)] = favorite ? date : nil
        saveMarks()
    }

    /// Right-click 「从列表隐藏」: out of 「最近」 until it's looked up again; the data stays.
    func hide(_ query: String, date: Date = Date()) {
        marks.hidden[HistoryRecord.key(query)] = date
        saveMarks()
    }

    private func saveMarks() {
        guard let marksURL, !marksUnreadable, let data = try? Self.encoder.encode(marks) else { return }
        do {
            try ensureDirectory()
            try data.write(to: marksURL, options: .atomic)
        } catch {
            NSLog("HoverDict: saving favorites failed: \(error)")
        }
    }

    private func ensureDirectory() throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

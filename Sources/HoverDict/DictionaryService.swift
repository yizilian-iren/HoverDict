import Foundation
import NaturalLanguage
import SQLite3

/// A dictionary lookup result.
struct DictionaryEntry {
    let word: String          // the headword actually matched (may be the lemma)
    let phonetic: String?     // IPA, e.g. "rʌn"
    let translation: String?  // Chinese definition (ECDICT `translation` column)
}

/// English→Chinese lookups against a local ECDICT SQLite database (`stardict.db`),
/// using the built-in libsqlite3 (no third-party dependency).
///
/// Lookup strategy:
///   1) exact match (case-insensitive),
///   2) if missing, lemmatize via NaturalLanguage (running→run, books→book) and retry.
final class DictionaryService {

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.hoverdict.dictionary")

    /// Open the database at `path`. Returns nil-safe; `isReady` reflects success.
    init?(databasePath path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("HoverDict: dictionary db not found at \(path)")
            return nil
        }
        // Read-only, no mutex needed since we serialize on our own queue.
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            NSLog("HoverDict: failed to open dictionary db: \(lastError)")
            return nil
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Look up a word (with lemmatization fallback). Synchronous; call off the main thread.
    func lookup(_ rawWord: String) -> DictionaryEntry? {
        let word = rawWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return nil }

        return queue.sync {
            if let hit = queryExact(word) { return hit }
            // Fallback: try the lemma (base form).
            let lemma = Self.lemmatize(word)
            if lemma.caseInsensitiveCompare(word) != .orderedSame,
               let hit = queryExact(lemma) {
                return hit
            }
            return nil
        }
    }

    // MARK: - SQLite

    /// ECDICT schema: table `stardict(word, phonetic, definition, translation, ...)`.
    /// We only read what the popup shows.
    private func queryExact(_ word: String) -> DictionaryEntry? {
        guard let db else { return nil }
        let sql = "SELECT word, phonetic, translation FROM stardict WHERE word = ? COLLATE NOCASE LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("HoverDict: prepare failed: \(lastError)")
            return nil
        }
        // SQLITE_TRANSIENT: let SQLite copy the string (Swift string is temporary).
        sqlite3_bind_text(stmt, 1, word, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let matched = column(stmt, 0) ?? word
        let phonetic = column(stmt, 1)
        let translation = column(stmt, 2)
        return DictionaryEntry(word: matched,
                               phonetic: phonetic?.nilIfEmpty,
                               translation: translation?.nilIfEmpty)
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private var lastError: String {
        guard let db else { return "no db" }
        return String(cString: sqlite3_errmsg(db))
    }

    // MARK: - Lemmatization

    /// Reduce a word to its dictionary base form using NaturalLanguage.
    /// Returns the original (lowercased) if no lemma is produced.
    static func lemmatize(_ word: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        let range = word.startIndex..<word.endIndex
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
        if let lemma = tag?.rawValue, !lemma.isEmpty {
            return lemma
        }
        _ = range
        return word.lowercased()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

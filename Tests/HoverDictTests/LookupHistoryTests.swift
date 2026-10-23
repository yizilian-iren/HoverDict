import AppKit
import Foundation
import Testing
@testable import HoverDict

@Suite struct LookupHistoryTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HoverDictTests-\(UUID().uuidString)")
    }

    private func typed(_ query: String, minutes: Double, zh: String = "意思", source: HistoryRecord.Source = .typed)
        -> HistoryRecord {
        HistoryRecord(query: query, language: TypedLanguage.detect(query).rawValue,
                      date: Date(timeIntervalSince1970: 1_000_000 + minutes * 60), source: source,
                      appName: "Safari", bundleID: "com.apple.Safari",
                      claude: StoredTranslation(ClaudeTranslation(zh: zh, ja: "意味", en: "meaning", note: "",
                                                                  model: .haiku)))
    }

    @Test func listsNewestFirstOncePerWordAndKeepsEveryLookup() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = LookupHistory(directory: dir)
        history.append(typed("alpha", minutes: 1))
        history.append(typed("beta", minutes: 2))
        history.append(typed("gamma", minutes: 3))
        history.append(typed("Alpha", minutes: 4, zh: "第二次"))

        let reopened = LookupHistory(directory: dir)
        #expect(reopened.records.count == 4)
        #expect(reopened.recent().map(\.query) == ["Alpha", "gamma", "beta"])
        #expect(reopened.recent(2).count == 2)
        #expect(reopened.savedClaude("alpha")?.zh == "第二次")
        #expect(reopened.savedClaude("alpha")?.model == .haiku)
        #expect(reopened.records.first?.bundleID == "com.apple.Safari")
    }

    @Test func clickedWordsAreKeptButNotListed() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = LookupHistory(directory: dir)
        history.append(typed("alpha", minutes: 1))
        history.append(typed("delta", minutes: 2, source: .click))
        let reopened = LookupHistory(directory: dir)
        #expect(reopened.records.map(\.source) == [.typed, .click])
        #expect(reopened.recent().map(\.query) == ["alpha"])
    }

    @Test func favoritesSurviveRelaunchAndLeaveRecent() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = LookupHistory(directory: dir)
        history.append(typed("alpha", minutes: 1))
        history.append(typed("beta", minutes: 2))
        history.setFavorite(true, for: "Alpha")

        var reopened = LookupHistory(directory: dir)
        #expect(reopened.isFavorite("alpha"))
        #expect(reopened.favorites.map(\.query) == ["alpha"])
        #expect(reopened.recent().map(\.query) == ["beta"])

        reopened.setFavorite(false, for: "alpha")
        reopened = LookupHistory(directory: dir)
        #expect(reopened.favorites.isEmpty)
        #expect(reopened.recent().map(\.query) == ["beta", "alpha"])
    }

    @Test func hidingKeepsTheDataUntilLookedUpAgain() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = LookupHistory(directory: dir)
        history.append(typed("alpha", minutes: 1))
        history.append(typed("beta", minutes: 2))
        history.hide("alpha", date: Date(timeIntervalSince1970: 1_000_000 + 3 * 60))

        var reopened = LookupHistory(directory: dir)
        #expect(reopened.recent().map(\.query) == ["beta"])
        #expect(reopened.records.count == 2)

        reopened.append(typed("alpha", minutes: 5))
        reopened = LookupHistory(directory: dir)
        #expect(reopened.recent().map(\.query) == ["alpha", "beta"])
    }

    @Test func skipsALineItCannotReadAndKeepsTheFile() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = LookupHistory(directory: dir)
        history.append(typed("alpha", minutes: 1))
        let file = dir.appendingPathComponent("history.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        history.append(typed("beta", minutes: 2))

        let reopened = LookupHistory(directory: dir)
        #expect(reopened.recent().map(\.query) == ["beta", "alpha"])
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 3)
    }

    @Test func neverOverwritesAFileItCannotOpenOrRead() throws {
        let dir = tempDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: dir.appendingPathComponent("history.jsonl").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let history = LookupHistory(directory: dir)
        history.append(typed("alpha", minutes: 1))
        history.append(typed("beta", minutes: 2))
        let file = dir.appendingPathComponent("history.jsonl")
        let before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        history.append(typed("gamma", minutes: 3))
        #expect(try Data(contentsOf: file) == before)

        let marks = dir.appendingPathComponent("marks.json")
        let broken = Data("{\"favorites\": {\"alpha\": oops".utf8)
        try broken.write(to: marks)
        let reopened = LookupHistory(directory: dir)
        reopened.setFavorite(true, for: "beta")
        reopened.hide("alpha")
        #expect(try Data(contentsOf: marks) == broken)
    }

    @Test func dictionaryTextRoundTripsAndGivesTheSummary() {
        let text = NSMutableAttributedString(string: "record\n", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        text.append(NSAttributedString(string: "记录；唱片", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        var record = HistoryRecord(query: "record", language: "en", date: Date(), source: .typed,
                                   dictionaryRTF: HistoryRecord.rtf(text))
        #expect(record.dictionary?.string == "record\n记录；唱片")
        #expect(record.summary == "记录；唱片")

        record.claude = StoredTranslation(ClaudeTranslation(zh: "记录（档案）；唱片", ja: "記録", en: "record", note: ""))
        #expect(record.summary == "记录")
        let chinese = HistoryRecord(query: "线程", language: "zh", date: Date(), source: .typed,
                                    claude: StoredTranslation(ClaudeTranslation(zh: "线程", ja: "スレッド",
                                                                                en: "thread (unit)", note: "")))
        #expect(chinese.summary == "thread")
        let lora = HistoryRecord(query: "lora", language: "en", date: Date(), source: .typed,
                                 claude: StoredTranslation(ClaudeTranslation(zh: "LoRA（低秩适配）；洛拉", ja: "LoRA",
                                                                             en: "LoRA", note: "")))
        #expect(lora.summary == "低秩适配")
    }

    @Test func readingIsSavedAndOldLinesStillOpen() throws {
        let stored = StoredTranslation(ClaudeTranslation(zh: "线程", ja: "スレッド", en: "thread", note: "",
                                                         reading: "/θrɛd/"))
        let data = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(StoredTranslation.self, from: data).translation.reading == "/θrɛd/")
        // A line from before I-31: no reading, and a dictionary block beside Claude's answer.
        let old = #"{"date":"2026-10-22T00:00:00Z","language":"en","query":"thread","source":"typed","#
            + #""claude":{"zh":"线程","ja":"スレッド","en":"thread","note":"","model":"claude-sonnet-5-5"},"#
            + #""dictionaryRTF":"e1xydGYxfQ=="}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(HistoryRecord.self, from: Data(old.utf8))
        let translation = try #require(record.claude?.translation)
        #expect(translation.reading.isEmpty && translation.zh == "线程" && translation.model == .sonnet)
        #expect(record.dictionaryRTF != nil)
    }
}

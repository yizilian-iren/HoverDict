import Foundation
import Testing
@testable import HoverDict

@Suite struct GlossaryTests {

    private let glossary = Glossary(text: """
    # comment = ignored
    thread = 线程；线
      Token=词元
    RAG = 检索增强生成
    SaaS = 软件即服务
    commit ＝ 提交
    broken line without equals
    empty =
    """)

    @Test func parsesEntriesAndSkipsCommentsAndBadLines() {
        #expect(glossary.lookup("thread") == "线程；线")
        #expect(glossary.lookup("token") == "词元")
        #expect(glossary.lookup("commit") == "提交")       // full-width ＝
        #expect(glossary.lookup("comment") == nil)
        #expect(glossary.lookup("empty") == nil)
        #expect(glossary.lookup("broken") == nil)
    }

    @Test func plainWordsIgnoreCaseAndTrailingPunctuation() {
        #expect(glossary.lookup("Thread") == "线程；线")
        #expect(glossary.lookup("THREAD") == "线程；线")
        #expect(glossary.lookup("thread,") == "线程；线")
    }

    @Test func inflectedFormsFallBackToTheLemma() {
        #expect(glossary.lookup("threads") == "线程；线")
        #expect(glossary.lookup("tokens") == "词元")
        #expect(glossary.lookup("committed") == "提交")
        #expect(glossary.lookup("commits") == "提交")
    }

    @Test func stemsCoverRegularEndings() {
        #expect(Glossary.stems(of: "caches").contains("cache"))
        #expect(Glossary.stems(of: "patches").contains("patch"))
        #expect(Glossary.stems(of: "queries").contains("query"))
        #expect(Glossary.stems(of: "merging").contains("merge"))
        #expect(Glossary.stems(of: "deploying").contains("deploy"))
        #expect(Glossary.stems(of: "committed").contains("commit"))
        #expect(Glossary.stems(of: "is").isEmpty)
    }

    @Test func acronymsMatchOnlyInCapitals() {
        #expect(glossary.lookup("RAG") == "检索增强生成")
        #expect(glossary.lookup("RAGs") == "检索增强生成")
        #expect(glossary.lookup("rag") == nil)
        #expect(glossary.lookup("Rag") == nil)
        #expect(glossary.lookup("SaaS") == "软件即服务")
    }

    @Test func acronymDetection() {
        #expect(Glossary.isAcronym("LLM"))
        #expect(Glossary.isAcronym("APIs"))
        #expect(Glossary.isAcronym("MoE"))
        #expect(!Glossary.isAcronym("Is"))
        #expect(!Glossary.isAcronym("Thread"))
        #expect(!Glossary.isAcronym("A"))
    }

    @Test func bundledGlossaryParsesAndCoversTheProblemWords() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/tech_glossary.txt")
        let tech = Glossary(contentsOf: url)
        for word in ["token", "thread", "cache", "commit", "bug", "chip", "weight", "agent", "LLM"] {
            #expect(tech.lookup(word) != nil, "missing \(word)")
        }
        #expect(tech.lookup("thread")?.hasPrefix("线程") == true)
    }

    @Test func userGlossaryPicksUpEditsWithoutRestart() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoverdict-glossary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = UserGlossary(url: dir.appendingPathComponent("custom.txt"))

        #expect(user.lookup("token") == nil)               // no file yet
        user.ensureExists()
        #expect(user.lookup("token") == nil)               // template is all comments

        try "token = 令牌\n".write(to: user.url, atomically: true, encoding: .utf8)
        // Make sure the modification date moves even within the same second.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: user.url.path)
        #expect(user.lookup("token") == "令牌")
    }
}

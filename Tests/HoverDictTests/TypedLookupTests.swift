import Foundation
import Testing
@testable import HoverDict

@Suite struct TypedLookupTests {

    @Test func detectsLanguage() {
        #expect(TypedLanguage.detect("convolutional neural network") == .en)
        #expect(TypedLanguage.detect("API") == .en)
        #expect(TypedLanguage.detect("畳み込み") == .ja)
        #expect(TypedLanguage.detect("ニューラルネットワーク") == .ja)
        #expect(TypedLanguage.detect("卷积神经网络") == .zh)
        #expect(TypedLanguage.detect("线程") == .zh)
    }

    @Test func glossaryReadsBackwards() {
        let glossary = Glossary(text: """
        thread = 线程；帖子（讨论串）；线
        fork = 分叉（复刻代码库）；叉子
        RAG = 检索增强生成
        """)
        #expect(glossary.reverseLookup("线程") == ["thread"])
        #expect(glossary.reverseLookup("分叉") == ["fork"])
        #expect(glossary.reverseLookup("帖子") == ["thread"])
        #expect(glossary.reverseLookup("检索增强生成") == ["RAG"])
        #expect(glossary.reverseLookup("讨论串").isEmpty)
        #expect(glossary.reverseLookup("").isEmpty)
    }

    @Test func parsesWikipediaPage() throws {
        let json = """
        {"query":{"pages":[{"title":"Convolutional neural network","extract":"A CNN is a network.",
        "langlinks":[{"lang":"ja","title":"畳み込みニューラルネットワーク"},
                     {"lang":"zh","title":"卷積神經網絡"},{"lang":"de","title":"CNN"}]}]}}
        """
        let page = try #require(WikiTerms.parsePage(Data(json.utf8)))
        #expect(page.title == "Convolutional neural network")
        #expect(page.links[.ja] == "畳み込みニューラルネットワーク")
        #expect(page.links[.zh] == "卷积神经网络")
        #expect(page.links[.en] == nil)
        #expect(page.extract == "A CNN is a network.")
        #expect(!page.isDisambiguation)
    }

    @Test func wikipediaMissingAndDisambiguation() {
        let missing = #"{"query":{"pages":[{"title":"Xyzzy","missing":true}]}}"#
        #expect(WikiTerms.parsePage(Data(missing.utf8)) == nil)
        let disambiguation = #"{"query":{"pages":[{"title":"Transformer","pageprops":{"disambiguation":""}}]}}"#
        #expect(WikiTerms.parsePage(Data(disambiguation.utf8))?.isDisambiguation == true)
        let simplified = #"{"query":{"pages":[{"title":"線程","varianttitles":{"zh-cn":"线程"}}]}}"#
        #expect(WikiTerms.parsePage(Data(simplified.utf8))?.title == "线程")
    }

    @Test func searchHitMustNameTheTerm() {
        #expect(WikiTerms.sameTerm("Transformer (deep learning)", "transformer"))
        #expect(WikiTerms.sameTerm("スレッド (コンピュータ)", "スレッド"))
        #expect(!WikiTerms.sameTerm("たべるんごのうた", "たべる"))
        #expect(!WikiTerms.sameTerm("Neural network", "network"))
    }

    @Test func readsClaudeTranslation() throws {
        let reply = #"""
        {"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},
         {"type":"text","text":"{\"zh\":\"变压器；Transformer 模型\",\"ja\":\"変圧器；Transformer\",\"en\":\"transformer\",\"note\":\"一种神经网络架构。\"}"}]}
        """#
        let result = ClaudeTranslator.parse(Data(reply.utf8))
        let translation = try result.get()
        #expect(translation.zh == "变压器；Transformer 模型")
        #expect(translation.text(for: .ja) == "変圧器；Transformer")
        #expect(translation.note == "一种神经网络架构。")

        let refused = #"{"stop_reason":"refusal","content":[]}"#
        #expect(ClaudeTranslator.parse(Data(refused.utf8)) == .failure(.refused))
        #expect(ClaudeTranslator.parse(Data("nope".utf8)) == .failure(.unreadable))
    }

    @Test func claudeRequestAsksForJSON() throws {
        let body = ClaudeTranslator.requestBody("线程", from: .zh)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        let output = try #require(body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "low")
        #expect((output["format"] as? [String: Any])?["type"] as? String == "json_schema")
        let prompt = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(prompt.contains("线程") && prompt.contains("Chinese term"))
    }
}

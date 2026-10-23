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

    @Test func splitsSenses() {
        #expect(Sense.split("LoRA（低秩适配）；洛拉（人名）") == [
            Sense(word: "LoRA", gloss: "低秩适配"), Sense(word: "洛拉", gloss: "人名")])
        #expect(Sense.split("Low-Rank Adaptation (fine-tuning method); LoRa (radio)") == [
            Sense(word: "Low-Rank Adaptation", gloss: "fine-tuning method"),
            Sense(word: "LoRa", gloss: "radio")])
        #expect(Sense.split("变压器；Transformer 模型；") == [
            Sense(word: "变压器", gloss: nil), Sense(word: "Transformer 模型", gloss: nil)])
        #expect(Sense.split("（注）") == [Sense(word: "（注）", gloss: nil)])
        #expect(Sense.split("C(++) 语言") == [Sense(word: "C(++) 语言", gloss: nil)])
        #expect(Sense.split("").isEmpty)
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
        #expect(translation.reading.isEmpty)

        let withReading = #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{\"reading\":\"/ˈθrɛd/\",\"zh\":\"线程\",\"ja\":\"スレッド\",\"en\":\"thread\",\"note\":\"\"}"}]}"#
        #expect(try ClaudeTranslator.parse(Data(withReading.utf8)).get().reading == "/ˈθrɛd/")

        let refused = #"{"stop_reason":"refusal","content":[]}"#
        #expect(ClaudeTranslator.parse(Data(refused.utf8)) == .failure(.refused))
        #expect(ClaudeTranslator.parse(Data("nope".utf8)) == .failure(.unreadable))
    }

    @Test func claudeRequestAsksForJSON() throws {
        let body = ClaudeTranslator.requestBody("线程", from: .zh, model: .opus)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["fallbacks"] as? String == "default")
        let output = try #require(body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "low")
        #expect((output["format"] as? [String: Any])?["type"] as? String == "json_schema")
        let prompt = try #require((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
        #expect(prompt.contains("线程") && prompt.contains("Chinese term"))
        // The reading comes first (I-31), and the prompt asks for the term's own reading.
        let schema = try #require((output["format"] as? [String: Any])?["schema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.first == "reading")
        #expect(prompt.contains("In reading") && prompt.contains("pinyin"))
    }

    @Test func fastModeTurnsThinkingDownWhereItCan() {
        func thinking(_ model: ClaudeModel, fast: Bool) -> String? {
            (ClaudeTranslator.requestBody("x", from: .en, model: model, fast: fast)["thinking"] as? [String: Any])?["type"] as? String
        }
        #expect(thinking(.sonnet, fast: true) == "between_tools")
        #expect(thinking(.haiku, fast: true) == "disabled")
        #expect(thinking(.opus, fast: true) == nil && thinking(.fable, fast: true) == nil)
        for model in ClaudeModel.allCases { #expect(thinking(model, fast: false) == nil) }
        // between_tools takes no other field in `thinking`, and only effort high or below.
        let body = ClaudeTranslator.requestBody("x", from: .en, model: .sonnet, fast: true)
        #expect((body["thinking"] as? [String: Any])?.count == 1)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test func claudeModelsAndDefault() {
        #expect(ClaudeModel.allCases.map(\.rawValue)
            == ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"])
        let haiku = ClaudeTranslator.requestBody("x", from: .en, model: .haiku)
        #expect(haiku["model"] as? String == "claude-haiku-5-5" && haiku["fallbacks"] == nil)
        #expect(haiku["thinking"] == nil)
    }

    /// The bench's variants (I-32): without fallbacks / without the schema, the rest the same.
    @Test func benchVariantsDropOnlyTheirPart() {
        let app = ClaudeTranslator.requestBody("x", from: .en, model: .sonnet, fast: true)
        #expect(app["fallbacks"] as? String == "default")
        #expect((app["output_config"] as? [String: Any])?["format"] != nil)
        let bare = ClaudeTranslator.requestBody("x", from: .en, model: .sonnet, fast: true, fallback: false, schema: false)
        #expect(bare["fallbacks"] == nil)
        let config = bare["output_config"] as? [String: Any]
        #expect(config?["format"] == nil && config?["effort"] as? String == "low")
        #expect(bare["thinking"] != nil)
        let prompt = ((bare["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        #expect(prompt.contains("only a JSON object"))
        #expect(ClaudeBench.median([3, 1, 2, 10]) == 2.5 && ClaudeBench.median([]) == nil)
    }
}

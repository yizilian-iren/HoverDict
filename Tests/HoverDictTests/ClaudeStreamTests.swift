import Foundation
import Testing
@testable import HoverDict

@Suite struct ClaudeStreamTests {

    /// A streamed answer as the Messages API sends it (event shapes from the API docs).
    static let sample = #"""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":187,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    event: ping
    data: {"type":"ping"}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"zh\":\"变压器；Trans"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"former 模型\",\"ja\":\"変圧器\",\"en\":\"transformer\",\"note\":\"一种\\\"神经网络\\\"架构。\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":42}}

    event: message_stop
    data: {"type":"message_stop"}
    """#

    @Test func readsAStreamedAnswer() throws {
        var stream = ClaudeStream()
        let added = Self.sample.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stream.feed(String($0)) }
        #expect(added.filter { $0 }.count == 2)
        #expect(stream.finished && stream.error == nil)
        #expect(stream.stopReason == "end_turn")
        #expect(stream.servedModel == "claude-sonnet-5-5")
        #expect(stream.inputTokens == 187 && stream.outputTokens == 42)
        let translation = try ClaudeTranslator.parse(text: stream.text, stopReason: stream.stopReason).get()
        #expect(translation.zh == "变压器；Transformer 模型")
        #expect(translation.note == #"一种"神经网络"架构。"#)
    }

    @Test func streamErrorsAndRefusals() {
        var stream = ClaudeStream()
        stream.feed(#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        #expect(stream.error == "Overloaded" && !stream.finished)

        var refused = ClaudeStream()
        refused.feed(#"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":0}}"#)
        refused.feed(#"data: {"type":"message_stop"}"#)
        #expect(ClaudeTranslator.parse(text: refused.text, stopReason: refused.stopReason) == .failure(.refused))
        #expect(ClaudeTranslator.parse(text: #"{"zh":"变"#, stopReason: "max_tokens") == .failure(.unreadable))
    }

    /// A mid-answer fallback: the next model goes on from the partial text in a new block.
    @Test func joinsTextAcrossAFallback() throws {
        var stream = ClaudeStream()
        for line in [
            #"data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":10}}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\"zh\":\"线"}}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-opus-4-8"}}}"#,
            #"data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"程\",\"ja\":\"スレッド\",\"en\":\"thread\",\"note\":\"\"}"}}"#,
            #"data: {"type":"message_stop"}"#,
        ] { stream.feed(line) }
        #expect(stream.servedModel == "claude-opus-4-8")
        #expect(try ClaudeTranslator.parse(text: stream.text, stopReason: "end_turn").get().zh == "线程")
    }

    @Test func readsUnfinishedJSON() {
        #expect(PartialJSON.fields("").closed.isEmpty)
        #expect(PartialJSON.fields(#"{"z"#).open == nil)
        let half = PartialJSON.fields(#"{"zh":"变压器；Trans"#)
        #expect(half.closed.isEmpty)
        #expect(half.open?.key == "zh" && half.open?.value == "变压器；Trans")
        let more = PartialJSON.fields(#"{"zh":"a\nb\"cé","ja": "x\u"#)
        #expect(more.closed == ["zh": "a\nb\"cé"])
        #expect(more.open?.key == "ja" && more.open?.value == "x")
        #expect(PartialJSON.fields(#"{"en":"emoji 😀","#).closed["en"] == "emoji 😀")
        #expect(PartialJSON.fields(#"{"en":"cut \"#).open?.value == "cut ")
    }

    /// Only whole senses show while it's written, and nothing before the first one ends.
    @Test func showsWholeSensesSoFar() throws {
        #expect(PartialJSON.translation(#"{"zh":"变压"#, model: .sonnet) == nil)
        let first = try #require(PartialJSON.translation(#"{"zh":"变压器；Trans"#, model: .sonnet))
        #expect(first.zh == "变压器" && first.ja.isEmpty)
        let next = try #require(PartialJSON.translation(#"{"zh":"变压器；Transformer","ja":"変圧"#, model: .sonnet))
        #expect(next.zh == "变压器；Transformer" && next.ja.isEmpty)
        let note = try #require(PartialJSON.translation(#"{"zh":"线程","note":"一种；执行"#, model: .sonnet))
        #expect(note.note.isEmpty)
        // The reading only once it's closed.
        #expect(PartialJSON.translation(#"{"reading":"/ˈθr"#, model: .sonnet) == nil)
        let read = try #require(PartialJSON.translation(#"{"reading":"/ˈθrɛd/","zh":"线程；"#, model: .sonnet))
        #expect(read.reading == "/ˈθrɛd/" && read.zh == "线程")
        let open = try #require(PartialJSON.translation(#"{"zh":"线程","reading":"/ˈθr"#, model: .sonnet))
        #expect(open.reading.isEmpty)
    }

    @Test func requestStreams() {
        #expect(ClaudeTranslator.requestBody("x", from: .en, model: .sonnet)["stream"] as? Bool == true)
    }

    @Test func timingGoesInTheHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoverdict-timing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let timing = ClaudeTiming(model: "claude-haiku-5-5", servedModel: "claude-haiku-5-5", ttfb: 0.41,
                                  firstText: 0.9, firstMeaning: 1.0, total: 1.6, inputTokens: 187, outputTokens: 42)
        #expect(timing.fast == nil)
        let fast = ClaudeTiming(model: "claude-sonnet-5-5", fast: true, total: 1)
        #expect(try JSONDecoder().decode(ClaudeTiming.self, from: JSONEncoder().encode(fast)).fast == true)
        #expect(abs((timing.generation ?? 0) - 0.7) < 1e-9)
        LookupHistory(directory: directory).append(HistoryRecord(
            query: "thread", language: "en", date: Date(), source: .typed, claudeTiming: timing))
        #expect(LookupHistory(directory: directory).recent().first?.claudeTiming == timing)
        // A line written before I-30 still reads.
        let old = #"{"date":"2026-10-23T00:00:00Z","language":"en","query":"old","source":"typed"}"#
        let record = try JSONDecoder.iso8601.decode(HistoryRecord.self, from: Data(old.utf8))
        #expect(record.claudeTiming == nil)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Without a schema (I-33) the answer may come fenced or with a line around it.
    @Test func parseToleratesFencesAndExtraText() throws {
        let object = #"{"reading":"/ˈloʊrə/","zh":"LoRA；低秩适配","ja":"LoRA","en":"LoRA","note":"微调方法 {见论文}"}"#
        for text in [object, "```json\n\(object)\n```", "Here it is:\n\(object)\nHope this helps.", "  \(object)  "] {
            let translation = try ClaudeTranslator.parse(text: text, stopReason: "end_turn").get()
            #expect(translation.zh == "LoRA；低秩适配" && translation.note == "微调方法 {见论文}"
                    && translation.reading == "/ˈloʊrə/")
        }
        // A quote and braces inside a string don't end the object early.
        let escaped = #"{"zh":"a\"}b","ja":"c","en":"d"} trailing {"zh":"no"}"#
        #expect(try ClaudeTranslator.parse(text: escaped, stopReason: "end_turn").get().zh == "a\"}b")
        // reading / note missing: still an answer; zh / ja / en missing or not strings: not.
        #expect(try ClaudeTranslator.parse(text: #"{"zh":"a","ja":"b","en":"c"}"#, stopReason: "end_turn").get().note == "")
        #expect(ClaudeTranslator.parse(text: #"{"zh":"a","ja":"b"}"#, stopReason: "end_turn") == .failure(.unreadable))
        #expect(ClaudeTranslator.parse(text: #"{"zh":"a","ja":"b","en":3}"#, stopReason: "end_turn") == .failure(.unreadable))
        #expect(ClaudeTranslator.parse(text: "```json\n{\"zh\":\"a\"", stopReason: "max_tokens") == .failure(.unreadable))
        #expect(ClaudeTranslator.parse(text: "抱歉，我不能。", stopReason: "end_turn") == .failure(.unreadable))
    }

    /// While streaming, a fence before the object doesn't stop the senses from showing.
    @Test func partialJSONSkipsAFence() {
        let partial = PartialJSON.translation("```json\n{\"reading\":\"x\",\"zh\":\"线程；执行", model: .sonnet)
        #expect(partial?.zh == "线程" && partial?.reading == "x")
        #expect(PartialJSON.firstObject("```json\n{\"zh\":\"a") == nil)
    }
}

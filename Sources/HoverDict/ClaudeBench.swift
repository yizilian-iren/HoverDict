import Foundation

/// `HoverDict --bench [out.md]` (I-32): where the seconds before Claude's first word go.
/// Four request variants × four words × two rounds on Sonnet 5.5 with 快速模式, interleaved so
/// no variant gets the warm streak, plus two `count_tokens` calls for the bare round trip.
/// No UI, no hot keys; the key comes from the Keychain like a lookup's and is never printed.
enum ClaudeBench {

    struct Variant {
        let name: String
        let label: String
        let fallback: Bool
        let schema: Bool
    }

    static let variants = [
        Variant(name: "A", label: "I-33 前的做法 (fallbacks + json_schema)", fallback: true, schema: true),
        Variant(name: "B", label: "去掉 fallbacks", fallback: false, schema: true),
        Variant(name: "C", label: "去掉 json_schema（I-33 起的做法）", fallback: true, schema: false),
        Variant(name: "D", label: "两个都去掉", fallback: false, schema: false),
    ]
    static let words: [(String, TypedLanguage)] = [("lora", .en), ("表示", .zh), ("うどん", .ja), ("人工智能", .zh)]
    static let rounds = 2
    static let model = ClaudeModel.sonnet
    /// Sonnet 5.5, $ per MTok (claude-api skill's price table, cached 2026-10-06).
    static let inputPrice = 2.0, outputPrice = 10.0

    struct Row {
        var label: String
        var status = 0
        /// The connection: set up for this request (DNS + TCP + TLS) or reused.
        var connect: Double?
        var reused: Bool?
        /// Request sent → response headers, from URLSessionTaskMetrics.
        var serverWait: Double?
        var ttfb: Double?
        var firstText: Double?
        var total: Double = 0
        var inputTokens: Int?
        var outputTokens: Int?
        var servedModel: String?
        var note = ""
    }

    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        var metrics: URLSessionTaskMetrics?
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            self.metrics = metrics
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    static func run(output: String?) async -> Int32 {
        guard let key = APIKeyStore.read() else {
            print("没有 API key（Keychain 里没有，或读取被拒）")
            return 1
        }
        var rows: [Row] = []
        var byVariant: [String: [Row]] = [:]

        rows.append(await countTokens(key: key, label: "count_tokens (冷)"))
        var n = 0
        for round in 0..<rounds {
            for (w, (word, language)) in words.enumerated() {
                // Rotate the variants' order each word and round: none always goes first.
                let shift = (w + round * 2) % variants.count
                for variant in variants[shift...] + variants[..<shift] {
                    n += 1
                    var row = await translate(key: key, word: word, language: language, variant: variant)
                    row.label = "\(variant.name) \(word) r\(round + 1)"
                    print(line(row))
                    rows.append(row)
                    byVariant[variant.name, default: []].append(row)
                }
            }
        }
        rows.append(await countTokens(key: key, label: "count_tokens (热)"))
        print(line(rows[0]))
        print(line(rows[rows.count - 1]))

        let report = markdown(rows: rows, byVariant: byVariant, requests: n + 2)
        print("\n" + report)
        if let output {
            do {
                try report.write(toFile: output, atomically: true, encoding: .utf8)
                print("写到了 \(output)")
            } catch {
                print("写不了 \(output): \(error)")
            }
        }
        return 0
    }

    private static func translate(key: String, word: String, language: TypedLanguage, variant: Variant) async -> Row {
        let bodyObject = ClaudeTranslator.requestBody(word, from: language, model: model, fast: true,
                                                      fallback: variant.fallback, schema: variant.schema)
        let body = (try? JSONSerialization.data(withJSONObject: bodyObject)) ?? Data()
        let request = ClaudeTranslator.apiRequest(key: key, body: body, fallback: variant.fallback)
        var row = Row(label: "")
        let delegate = MetricsDelegate()
        let start = ProcessInfo.processInfo.systemUptime
        func now() -> Double { ProcessInfo.processInfo.systemUptime - start }

        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            row.ttfb = now()
            row.status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var stream = ClaudeStream()
            var errorText = ""
            for try await line in bytes.lines {
                if row.status != 200 { errorText += line; continue }
                if stream.feed(line), row.firstText == nil { row.firstText = now() }
            }
            row.total = now()
            row.inputTokens = stream.inputTokens
            row.outputTokens = stream.outputTokens
            row.servedModel = stream.servedModel
            if row.status != 200 {
                row.note = String(errorText.prefix(160))
            } else if case .failure = ClaudeTranslator.parse(text: stream.text, stopReason: stream.stopReason) {
                row.note = "JSON 读不出"
            } else if stream.stopReason == "refusal" {
                row.note = "refusal"
            }
        } catch {
            row.total = now()
            row.note = "\(error.localizedDescription)"
        }
        await fill(&row, from: delegate)
        return row
    }

    /// The bare round trip with the key: the API's auth and routing, no model.
    private static func countTokens(key: String, label: String) async -> Row {
        let bodyObject: [String: Any] = ["model": model.rawValue, "messages": [["role": "user", "content": "lora"]]]
        let body = (try? JSONSerialization.data(withJSONObject: bodyObject)) ?? Data()
        let url = URL(string: "https://api.anthropic.com/v1/messages/count_tokens")!
        let request = ClaudeTranslator.apiRequest(key: key, body: body, fallback: false, url: url)
        var row = Row(label: label)
        let delegate = MetricsDelegate()
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let (_, response) = try await session.data(for: request, delegate: delegate)
            row.status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            row.note = "\(error.localizedDescription)"
        }
        row.total = ProcessInfo.processInfo.systemUptime - start
        row.ttfb = row.total
        await fill(&row, from: delegate)
        return row
    }

    private static func fill(_ row: inout Row, from delegate: MetricsDelegate) async {
        // The metrics arrive just after the task ends.
        for _ in 0..<20 where delegate.metrics == nil { try? await Task.sleep(nanoseconds: 25_000_000) }
        guard let t = delegate.metrics?.transactionMetrics.last else { return }
        row.reused = t.isReusedConnection
        if let a = t.domainLookupStartDate ?? t.connectStartDate, let b = t.connectEndDate {
            row.connect = b.timeIntervalSince(a)
        }
        if let a = t.requestEndDate, let b = t.responseStartDate { row.serverWait = b.timeIntervalSince(a) }
    }

    // MARK: - Report

    private static func f(_ x: Double?) -> String { x.map { String(format: "%.2f", $0) } ?? "–" }

    private static func line(_ r: Row) -> String {
        "\(r.label)\t\(r.status)\tconnect \(r.reused == true ? "reused" : f(r.connect))\twait \(f(r.serverWait))"
            + "\tttfb \(f(r.ttfb))\tfirstText \(f(r.firstText))\ttotal \(f(r.total))"
            + "\tin \(r.inputTokens.map(String.init) ?? "–") out \(r.outputTokens.map(String.init) ?? "–") \(r.note)"
    }

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func markdown(rows: [Row], byVariant: [String: [Row]], requests: Int) -> String {
        let input = rows.compactMap(\.inputTokens).reduce(0, +)
        let output = rows.compactMap(\.outputTokens).reduce(0, +)
        let cost = Double(input) / 1e6 * inputPrice + Double(output) / 1e6 * outputPrice
        var md = """
        # I-32 Claude 翻译测速

        \(model.displayName)，快速模式（thinking between_tools，effort low），stream。\
        \(words.count) 个词 × \(variants.count) 个变体 × \(rounds) 轮，交错顺序；另加 2 次 count_tokens。秒。

        ## 每个变体的中位数

        | 变体 | 做法 | n | ttfb | firstText | total | out tokens | 出错 |
        |---|---|---|---|---|---|---|---|

        """
        for v in variants {
            let rs = byVariant[v.name] ?? []
            let ok = rs.filter { $0.status == 200 }
            md += "| \(v.name) | \(v.label) | \(ok.count) | \(f(median(ok.compactMap(\.ttfb)))) | "
                + "\(f(median(ok.compactMap(\.firstText)))) | \(f(median(ok.map(\.total)))) | "
                + "\(median(ok.compactMap(\.outputTokens).map(Double.init)).map { String(Int($0)) } ?? "–") | "
                + "\(rs.filter { !$0.note.isEmpty || $0.status != 200 }.count) |\n"
        }
        md += """

        ## 每一次

        | 请求 | HTTP | 连接 | 等响应头 | ttfb | firstText | total | in | out | 备注 |
        |---|---|---|---|---|---|---|---|---|---|

        """
        for r in rows {
            md += "| \(r.label) | \(r.status) | \(r.reused == true ? "复用" : f(r.connect)) | \(f(r.serverWait)) | "
                + "\(f(r.ttfb)) | \(f(r.firstText)) | \(f(r.total)) | \(r.inputTokens.map(String.init) ?? "–") | "
                + "\(r.outputTokens.map(String.init) ?? "–") | \(r.note) |\n"
        }
        md += """

        ## 花费

        \(requests) 次请求；input \(input) tokens，output \(output) tokens；\
        按 $\(Int(inputPrice)) / $\(Int(outputPrice)) per MTok 约 $\(String(format: "%.4f", cost))。

        """
        return md
    }
}

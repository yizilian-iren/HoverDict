import Foundation

/// How long one Claude request took and what it cost (I-30), kept with its history line so
/// the models can be compared later. Seconds from when the request was sent.
struct ClaudeTiming: Codable, Equatable {
    /// The model asked for, and the one that answered (another after a server-side fallback).
    var model: String
    var servedModel: String?
    /// Sent with 快速模式 on (I-31); nil in lines written before it.
    var fast: Bool?
    /// The response headers arrived: connection, TLS and the API's queueing, before any work.
    var ttfb: Double?
    /// The first piece of the answer's text: everything before it is fixed cost (and thinking).
    var firstText: Double?
    /// The first sense was on the card.
    var firstMeaning: Double?
    var total: Double
    var inputTokens: Int?
    var outputTokens: Int?
    /// Why there was no answer (nil = it was shown).
    var failure: String?

    /// From the first text to the last: the time spent writing the answer.
    var generation: Double? { firstText.map { total - $0 } }
}

/// Reads the Messages API's server-sent events (`stream: true`) one line at a time.
/// The answer's text is every text block's deltas joined: after a mid-answer fallback the
/// next model continues the partial text in a new block, after a `fallback` block.
struct ClaudeStream {
    private(set) var text = ""
    private(set) var stopReason: String?
    private(set) var servedModel: String?
    private(set) var inputTokens: Int?
    private(set) var outputTokens: Int?
    /// An `error` event: the stream ended without an answer.
    private(set) var error: String?
    private(set) var finished = false

    /// Feeds one line; true when it added text.
    @discardableResult
    mutating func feed(_ line: String) -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return false
        }
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any]
            servedModel = message?["model"] as? String
            readUsage(message?["usage"])
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            if block?["type"] as? String == "fallback" {
                servedModel = (block?["to"] as? [String: Any])?["model"] as? String ?? servedModel
            }
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta", let piece = delta?["text"] as? String, !piece.isEmpty {
                text += piece
                return true
            }
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            readUsage(event["usage"])
        case "message_stop":
            finished = true
        case "error":
            error = (event["error"] as? [String: Any])?["message"] as? String ?? "出错了"
        default:
            break
        }
        return false
    }

    private mutating func readUsage(_ usage: Any?) {
        guard let usage = usage as? [String: Any] else { return }
        if let input = usage["input_tokens"] as? Int { inputTokens = input }
        if let output = usage["output_tokens"] as? Int { outputTokens = output }
    }
}

/// The string fields of a JSON object that is still being written ("{\"zh\":\"变压器；Tra").
enum PartialJSON {

    /// Fields whose string is closed, and the one still open (its text so far).
    static func fields(_ text: String) -> (closed: [String: String], open: (key: String, value: String)?) {
        var scanner = Scanner(Array(text.unicodeScalars))
        var closed: [String: String] = [:]
        scanner.skipSpace()
        guard scanner.take("{") else { return ([:], nil) }
        while true {
            scanner.skipSpace()
            _ = scanner.take(",")
            scanner.skipSpace()
            guard scanner.take("\""), case let (key, true) = scanner.string() else { break }
            scanner.skipSpace()
            guard scanner.take(":") else { break }
            scanner.skipSpace()
            guard scanner.take("\"") else { break }
            let (value, done) = scanner.string()
            guard done else { return (closed, (key, value)) }
            closed[key] = value
        }
        return (closed, nil)
    }

    /// What can be shown of an answer so far: closed fields whole, and of the open one only
    /// the senses already ended by "；", so no line is shown half-written (the reading and
    /// the note only once closed).
    static func translation(_ text: String, model: ClaudeModel) -> ClaudeTranslation? {
        var (fields, open) = fields(text)
        if let open, open.key != "note", open.key != "reading",
           let end = open.value.lastIndex(where: { $0 == "；" || $0 == ";" }) {
            fields[open.key] = String(open.value[..<end])
        }
        let translation = ClaudeTranslation(zh: fields["zh"] ?? "", ja: fields["ja"] ?? "",
                                            en: fields["en"] ?? "", note: fields["note"] ?? "",
                                            reading: fields["reading"] ?? "", model: model)
        let shown = TypedLanguage.displayOrder.contains { !Sense.split(translation.text(for: $0)).isEmpty }
        return shown ? translation : nil
    }

    private struct Scanner {
        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func skipSpace() {
            while index < scalars.count, scalars[index].properties.isWhitespace { index += 1 }
        }

        mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard index < scalars.count, scalars[index] == scalar else { return false }
            index += 1
            return true
        }

        /// After the opening quote: the string's text, and whether its closing quote came.
        /// An escape cut off at the end is left out.
        mutating func string() -> (String, Bool) {
            var out = String.UnicodeScalarView()
            var pendingHigh: UInt32?
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                if c == "\"" { return (String(out), true) }
                guard c == "\\" else {
                    out.append(c)
                    continue
                }
                guard index < scalars.count else { break }
                let e = scalars[index]
                index += 1
                switch e {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{c}")
                case "u":
                    guard index + 4 <= scalars.count,
                          let code = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16)
                    else { return (String(out), false) }
                    index += 4
                    if (0xD800..<0xDC00).contains(code) {
                        pendingHigh = code
                    } else if (0xDC00..<0xE000).contains(code), let high = pendingHigh {
                        pendingHigh = nil
                        if let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)) {
                            out.append(scalar)
                        }
                    } else if let scalar = Unicode.Scalar(code) {
                        out.append(scalar)
                    }
                default: out.append(e) // \" \\ \/
                }
            }
            return (String(out), false)
        }
    }
}

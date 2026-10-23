import Foundation
import Security

/// The typed term in 中 / 日 / 英 from Claude, every main sense (technical first), its
/// reading (I-31), plus a one-line Chinese note. Uses the Messages API with the user's own key (menu
/// Claude API key…), kept in the Keychain.
struct ClaudeTranslation: Equatable {
    var zh: String
    var ja: String
    var en: String
    var note: String
    /// How the typed term itself is read: IPA for English, kana for Japanese, pinyin for
    /// Chinese. Empty in answers saved before I-31.
    var reading: String = ""
    /// The model that answered, shown on the card.
    var model: ClaudeModel = ClaudeModel.current
    /// How long the request took, for the card; nil when it came from the history.
    var seconds: Double?

    func text(for language: TypedLanguage) -> String {
        switch language {
        case .zh: zh
        case .ja: ja
        case .en: en
        }
    }
}

/// The models the Claude translation can use (menu Claude 模型), saved in UserDefaults.
enum ClaudeModel: String, CaseIterable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    case fable = "claude-fable-5-1"

    static let defaultsKey = "HoverDict.claudeModel"

    static var current: ClaudeModel {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(ClaudeModel.init(rawValue:)) ?? .sonnet }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var displayName: String {
        switch self {
        case .haiku: "Haiku 5.5"
        case .sonnet: "Sonnet 5.5"
        case .opus: "Opus 5.5"
        case .fable: "Fable 5.1"
        }
    }

    /// Haiku 5.5 has no server-side fallback for safety declines.
    var supportsFallback: Bool { self != .haiku }

    /// What 快速模式 sends as `thinking` (I-31): the lowest setting each model takes —
    /// Sonnet 5.5 `between_tools`, Haiku 5.5 `disabled` (both only at effort high or below;
    /// the request uses low). Opus 5.5 and Fable 5.1 can't turn thinking off: nothing sent.
    var fastThinking: [String: Any]? {
        switch self {
        case .sonnet: ["type": "between_tools"]
        case .haiku: ["type": "disabled"]
        case .opus, .fable: nil
        }
    }
}

/// Menu 快速模式（少 thinking）, on unless turned off; saved in UserDefaults.
enum ClaudeFastMode {
    static let defaultsKey = "HoverDict.claudeFastMode"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

enum ClaudeTranslator {

    enum Failure: Error, Equatable {
        case noKey
        case http(Int, String)
        case refused
        case unreadable
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Streams the answer (I-30): `partial` gets what can be shown so far each time it
    /// grows, the result the whole answer; the timing goes into the history.
    static func translate(_ term: String, from language: TypedLanguage,
                          model: ClaudeModel = .current, fast: Bool = ClaudeFastMode.isOn,
                          partial: @escaping @MainActor (ClaudeTranslation) -> Void = { _ in })
        async -> (Result<ClaudeTranslation, Failure>, ClaudeTiming?) {
        guard let key = APIKeyStore.read() else { return (.failure(.noKey), nil) }
        guard let body = try? JSONSerialization.data(withJSONObject: requestBody(term, from: language, model: model, fast: fast)) else {
            return (.failure(.unreadable), nil)
        }
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // `fallbacks: "default"`: a safety decline is retried on a fallback model in the same call.
        if model.supportsFallback {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = body

        let start = ProcessInfo.processInfo.systemUptime
        func now() -> Double { ((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded() / 1000 }
        var timing = ClaudeTiming(model: model.rawValue, fast: fast, total: 0)
        func finish(_ result: Result<ClaudeTranslation, Failure>) -> (Result<ClaudeTranslation, Failure>, ClaudeTiming?) {
            timing.total = now()
            switch result {
            case .success(var translation):
                translation.seconds = timing.total
                return (.success(translation), timing)
            case .failure(let failure):
                timing.failure = "\(failure)"
                return (result, timing)
            }
        }

        guard let (bytes, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse else {
            return finish(.failure(.http(0, "连不上 api.anthropic.com")))
        }
        timing.ttfb = now()
        guard http.statusCode == 200 else {
            var data = Data()
            do {
                for try await byte in bytes where data.count < 64_000 { data.append(byte) }
            } catch {}
            return finish(.failure(.http(http.statusCode, errorMessage(data) ?? "")))
        }

        var stream = ClaudeStream()
        var shown: ClaudeTranslation?
        do {
            for try await line in bytes.lines {
                guard stream.feed(line) else { continue }
                if timing.firstText == nil { timing.firstText = now() }
                if let sofar = PartialJSON.translation(stream.text, model: model), sofar != shown {
                    if shown == nil { timing.firstMeaning = now() }
                    shown = sofar
                    await partial(sofar)
                }
            }
        } catch {
            NSLog("HoverDict: Claude stream broke off: \(error)")
        }
        timing.servedModel = stream.servedModel
        timing.inputTokens = stream.inputTokens
        timing.outputTokens = stream.outputTokens
        if let message = stream.error { return finish(.failure(.http(0, message))) }
        guard stream.finished else { return finish(.failure(.http(0, "连接中断"))) }
        return finish(parse(text: stream.text, stopReason: stream.stopReason, model: model))
    }

    /// ⌥Z opened the window: get the connection to the API (DNS, TCP, TLS) ready while the
    /// word is typed, so the lookup doesn't pay for it. A HEAD without a key — refused at
    /// once, no tokens — on the same session, whose connection the lookup then reuses.
    static func preconnect() {
        let now = ProcessInfo.processInfo.systemUptime
        preconnectLock.lock()
        defer { preconnectLock.unlock() }
        guard now - lastPreconnect > 15 else { return }
        lastPreconnect = now
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        session.dataTask(with: request).resume()
    }

    private static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let preconnectLock = NSLock()
    private static var lastPreconnect: TimeInterval = -.infinity

    static func requestBody(_ term: String, from language: TypedLanguage,
                            model: ClaudeModel = .current, fast: Bool = false) -> [String: Any] {
        // The reading first: it's short, so it is on the card with the first sense.
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "reading": ["type": "string"],
                "zh": ["type": "string"],
                "ja": ["type": "string"],
                "en": ["type": "string"],
                "note": ["type": "string"],
            ],
            "required": ["reading", "zh", "ja", "en", "note"],
            "additionalProperties": false,
        ]
        let prompt = """
        A reader who works in tech looked up this \(language.englishName) term: \(term)

        Give it in Simplified Chinese (zh), Japanese (ja) and English (en). If it has several \
        common meanings, list the main ones in each language separated by "；", the technical \
        (computing / science / engineering) meaning first. Use the names people in the field \
        actually use (e.g. Transformer stays "Transformer" in Chinese and Japanese). \
        In reading, how the looked-up term itself is pronounced, nothing else: IPA between \
        slashes for English (e.g. /ˈθrɛd/), kana for Japanese (e.g. すいろん), pinyin with tone \
        marks for Chinese (e.g. xiànchéng). Leave it empty for an acronym read letter by letter \
        or when there is no common reading.
        In note, one short sentence in Simplified Chinese saying what it is, technical sense first.
        """
        // Low effort keeps it quick; 快速模式 also turns thinking down where the model allows.
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 2000,
            "stream": true,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": prompt]],
        ]
        if model.supportsFallback { body["fallbacks"] = "default" }
        if fast, let thinking = model.fastThinking { body["thinking"] = thinking }
        return body
    }

    static func parse(_ data: Data, model: ClaudeModel = .current) -> Result<ClaudeTranslation, Failure> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable)
        }
        let text = (root["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        return parse(text: text, stopReason: root["stop_reason"] as? String, model: model)
    }

    /// The answer's text (the JSON the schema asks for) and why it stopped.
    static func parse(text: String, stopReason: String?, model: ClaudeModel = .current) -> Result<ClaudeTranslation, Failure> {
        if stopReason == "refusal" { return .failure(.refused) }
        guard let fields = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String],
              let zh = fields["zh"], let ja = fields["ja"], let en = fields["en"] else {
            return .failure(.unreadable)
        }
        return .success(ClaudeTranslation(zh: zh, ja: ja, en: en, note: fields["note"] ?? "",
                                          reading: fields["reading"] ?? "", model: model))
    }

    private static func errorMessage(_ data: Data) -> String? {
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (root?["error"] as? [String: Any])?["message"] as? String
    }
}

private extension TypedLanguage {
    var englishName: String {
        switch self {
        case .zh: "Chinese"
        case .ja: "Japanese"
        case .en: "English"
        }
    }
}

/// The Anthropic API key, in the login Keychain (never in UserDefaults or a file).
enum APIKeyStore {
    private static let service = "com.hoverdict.anthropic-api-key"
    private static let account = "default"

    /// The key is read from the Keychain at most once per launch and then kept in memory,
    /// so Keychain's "wants to access" prompt can't come back on every lookup. A denied
    /// read (Deny / Cancel) is remembered too, until the user saves a key from the menu.
    private static let lock = NSLock()
    private static var cached: String?
    private static var loaded = false

    static func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        if loaded { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // Not found: ask again next time (the user may add a key). Denied: don't.
        if status != errSecItemNotFound { loaded = true }
        guard status == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        cached = key
        return key
    }

    /// An empty key removes it.
    @discardableResult
    static func save(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(base as CFDictionary)
        cached = nil
        loaded = false
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
        cached = trimmed
        loaded = true
        return true
    }
}

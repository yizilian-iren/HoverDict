import Foundation
import Security

/// The typed term in 中 / 日 / 英 from Claude, every main sense (technical first), plus a
/// one-line Chinese note. Uses the Messages API with the user's own key (menu
/// Claude API key…), kept in the Keychain.
struct ClaudeTranslation: Equatable {
    var zh: String
    var ja: String
    var en: String
    var note: String
    /// The model that answered, shown on the card.
    var model: ClaudeModel = ClaudeModel.current

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

    static func translate(_ term: String, from language: TypedLanguage,
                          model: ClaudeModel = .current) async -> Result<ClaudeTranslation, Failure> {
        guard let key = APIKeyStore.read() else { return .failure(.noKey) }
        guard let body = try? JSONSerialization.data(withJSONObject: requestBody(term, from: language, model: model)) else {
            return .failure(.unreadable)
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        // `fallbacks: "default"`: a safety decline is retried on a fallback model in the same call.
        if model.supportsFallback {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = body
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failure(.http(0, "连不上 api.anthropic.com"))
        }
        guard http.statusCode == 200 else {
            return .failure(.http(http.statusCode, errorMessage(data) ?? ""))
        }
        return parse(data, model: model)
    }

    static func requestBody(_ term: String, from language: TypedLanguage,
                            model: ClaudeModel = .current) -> [String: Any] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "zh": ["type": "string"],
                "ja": ["type": "string"],
                "en": ["type": "string"],
                "note": ["type": "string"],
            ],
            "required": ["zh", "ja", "en", "note"],
            "additionalProperties": false,
        ]
        let prompt = """
        A reader who works in tech looked up this \(language.englishName) term: \(term)

        Give it in Simplified Chinese (zh), Japanese (ja) and English (en). If it has several \
        common meanings, list the main ones in each language separated by "；", the technical \
        (computing / science / engineering) meaning first. Use the names people in the field \
        actually use (e.g. Transformer stays "Transformer" in Chinese and Japanese). \
        In note, one short sentence in Simplified Chinese saying what it is, technical sense first.
        """
        // None of these models accept `thinking: disabled`; low effort keeps it quick.
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 2000,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": prompt]],
        ]
        if model.supportsFallback { body["fallbacks"] = "default" }
        return body
    }

    static func parse(_ data: Data, model: ClaudeModel = .current) -> Result<ClaudeTranslation, Failure> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable)
        }
        if root["stop_reason"] as? String == "refusal" { return .failure(.refused) }
        let text = (root["content"] as? [[String: Any]] ?? [])
            .first { $0["type"] as? String == "text" }?["text"] as? String
        guard let json = text?.data(using: .utf8),
              let fields = try? JSONSerialization.jsonObject(with: json) as? [String: String],
              let zh = fields["zh"], let ja = fields["ja"], let en = fields["en"] else {
            return .failure(.unreadable)
        }
        return .success(ClaudeTranslation(zh: zh, ja: ja, en: en, note: fields["note"] ?? "", model: model))
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

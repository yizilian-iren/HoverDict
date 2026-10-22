import Foundation
import NaturalLanguage

/// What the typed-lookup window (⌥Z) works with: which of 中 / 日 / 英 the input is,
/// and the Wikipedia titles that give a term's name in all three.
enum TypedLanguage: String, CaseIterable {
    case en, ja, zh

    /// Locale identifier for the Translation framework.
    var localeID: String {
        switch self {
        case .en: "en"
        case .ja: "ja"
        case .zh: "zh-Hans"
        }
    }

    /// Google TTS `tl` code (TTSPlayer) and the system voice to fall back to.
    var ttsCode: String {
        switch self {
        case .en: "en"
        case .ja: "ja"
        case .zh: "zh-CN"
        }
    }
    var voiceID: String {
        switch self {
        case .en: "en-US"
        case .ja: "ja-JP"
        case .zh: "zh-CN"
        }
    }

    /// Display order in the window: Chinese first for a Chinese reader.
    static let displayOrder: [TypedLanguage] = [.zh, .ja, .en]

    var name: String {
        switch self {
        case .en: "英"
        case .ja: "日"
        case .zh: "中"
        }
    }

    /// Kana → Japanese; Han only → Chinese unless NaturalLanguage is sure it's Japanese
    /// (機械学習 reads the same either way, and the translators handle both); else English.
    static func detect(_ text: String) -> TypedLanguage {
        if JapaneseText.containsKana(text) { return .ja }
        guard JapaneseText.containsKanji(text) else { return .en }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese, .japanese]
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        if let ja = hypotheses[.japanese], ja > 0.8 { return .ja }
        return .zh
    }
}

/// A Wikipedia article found for the typed term: its title in each language that has
/// one, and the start of its introduction (Chinese when there is a Chinese article).
struct WikiTerm: Equatable {
    var titles: [TypedLanguage: String]
    var summary: String?
}

/// Wikipedia's action API (no key). One request on the input's own wiki finds the
/// article and its ja / zh / en links; a second fetches the simplified-Chinese intro.
enum WikiTerms {

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config)
    }()

    static func lookup(_ term: String, language: TypedLanguage) async -> WikiTerm? {
        var page = await fetchPage(title: term, language: language)
        if page == nil || page?.isDisambiguation == true {
            // No article under that exact name (or only a list of meanings): take the
            // search's best hit instead.
            if let best = await searchTitle(term, language: language, excluding: page?.title) {
                page = await fetchPage(title: best, language: language)
            }
        }
        guard let page, !page.isDisambiguation else { return nil }

        var result = WikiTerm(titles: page.links, summary: page.extract)
        result.titles[language] = page.title
        if language != .zh, let zhTitle = page.links[.zh],
           let zh = await fetchPage(title: zhTitle, language: .zh) {
            result.titles[.zh] = zh.title
            if let extract = zh.extract { result.summary = extract }
        }
        return result
    }

    struct Page: Equatable {
        var title: String
        var extract: String?
        var links: [TypedLanguage: String]
        var isDisambiguation: Bool
    }

    private static func apiURL(_ language: TypedLanguage, _ items: [URLQueryItem]) -> URL? {
        var comps = URLComponents(string: "https://\(language.rawValue).wikipedia.org/w/api.php")!
        var query: [URLQueryItem] = [
            .init(name: "action", value: "query"),
            .init(name: "format", value: "json"),
            .init(name: "formatversion", value: "2"),
        ]
        if language == .zh {
            query.append(.init(name: "variant", value: "zh-cn"))
        }
        comps.queryItems = query + items
        return comps.url
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        // Wikimedia asks API clients to identify themselves.
        request.setValue("HoverDict/1.0 (https://github.com/yizilian-iren/HoverDict)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    private static func fetchPage(title: String, language: TypedLanguage) async -> Page? {
        guard let url = apiURL(language, [
            .init(name: "titles", value: title),
            .init(name: "redirects", value: "1"),
            .init(name: "converttitles", value: "1"),
            .init(name: "prop", value: "langlinks|extracts|pageprops|info"),
            .init(name: "inprop", value: "varianttitles"),
            .init(name: "ppprop", value: "disambiguation"),
            .init(name: "lllimit", value: "max"),
            .init(name: "exintro", value: "1"),
            .init(name: "explaintext", value: "1"),
            .init(name: "exsentences", value: "2"),
        ]), let data = await get(url) else { return nil }
        return parsePage(data)
    }

    private static func searchTitle(_ term: String, language: TypedLanguage,
                                    excluding: String?) async -> String? {
        guard let url = apiURL(language, [
            .init(name: "list", value: "search"),
            .init(name: "srsearch", value: term),
            .init(name: "srlimit", value: "10"),
        ]), let data = await get(url) else { return nil }
        return parseSearch(data).first { $0 != excluding && sameTerm($0, term) }
    }

    /// A search hit only counts when it names the typed term itself, give or take a
    /// "(…)" qualifier: transformer → "Transformer (deep learning)", but not たべる →
    /// "たべるんごのうた" (a song that merely starts with it).
    static func sameTerm(_ title: String, _ term: String) -> Bool {
        var base = title
        if let open = base.firstIndex(where: { $0 == "(" || $0 == "（" }) {
            base = String(base[..<open])
        }
        return base.trimmingCharacters(in: .whitespaces)
            .caseInsensitiveCompare(term.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The first page of a `formatversion=2` query, or nil when it's missing.
    static func parsePage(_ data: Data) -> Page? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let page = (query["pages"] as? [[String: Any]])?.first,
              page["missing"] == nil, page["invalid"] == nil,
              var title = page["title"] as? String else { return nil }
        if let simplified = (page["varianttitles"] as? [String: String])?["zh-cn"] {
            title = simplified
        }
        var links: [TypedLanguage: String] = [:]
        for link in page["langlinks"] as? [[String: Any]] ?? [] {
            guard let code = link["lang"] as? String, let name = link["title"] as? String,
                  let lang = TypedLanguage(rawValue: code) else { continue }
            links[lang] = lang == .zh ? simplify(name) : name
        }
        let extract = (page["extract"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let props = page["pageprops"] as? [String: Any]
        return Page(title: title,
                    extract: extract?.isEmpty == false ? extract : nil,
                    links: links,
                    isDisambiguation: props?["disambiguation"] != nil)
    }

    static func parseSearch(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let hits = query["search"] as? [[String: Any]] else { return [] }
        return hits.compactMap { $0["title"] as? String }
    }

    /// zh.wikipedia language links come in whatever script the article was named in.
    static func simplify(_ text: String) -> String {
        text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
    }
}

import Testing
@testable import HoverDict

@Suite struct OxfordDictionaryTests {

    // MARK: - Parsing

    /// A made-up entry in the dictionary's markup (not copied from it): two
    /// part-of-speech groups, labels of every kind, pinyin, collocates, an example, a
    /// sense with two targets, and a phrasal-verb block that must be ignored.
    private let glimmer = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <html xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><body>
    <d:entry id="e_test1" d:title="glimmer" class="entry">
    <span class="hwg x_xh0"><span class="hw">glimmer </span><span class="prx"><span class="ph">ˈɡlɪmə</span></span><span class="lev">informal </span></span>
    <span class="gramb x_xd0 hasSn"><span class="x_xdh"><span class="gp sn ty_label tg_gramb">A.</span><span class="ps">intransitive verb </span></span>
      <span class="semb x_xd1 hasSn"><span class="gp x_xdh sn ty_label tg_semb">① </span>
        <span class="trgg x_xd2">
          <span class="trg"><span class="ind"><span class="gp tg_ind">(</span>shine faintly<span class="gp tg_ind">) </span></span><span class="trans">闪烁 </span><span class="trans ty_pinyin">shǎnshuò </span><span class="co"><span class="gp tg_co">‹</span>light<span class="gp tg_co">›</span></span><span class="gp tg_trg">; </span></span>
          <span class="trg"><span class="trans">发微光 </span><span class="trans ty_pinyin">fā wēiguāng </span></span>
        </span>
        <span class="exg x_xd2 hasSn"><span class="x_xdh"><span class="sn">▸ </span><span class="ex">a lamp glimmered </span></span><span class="trg x_xd3"><span class="trans">一盏灯闪着微光 </span></span></span>
      </span>
      <span class="semb x_xd1 hasSn"><span class="gp x_xdh sn ty_label tg_semb">② </span>
        <span class="trg x_xd2"><span class="lev">figurative </span><span class="fld">Finance<span class="gp tg_fld">, </span></span><span class="fld">Law </span><span class="ind"><span class="gp tg_ind">(</span>appear<span class="gp tg_ind">) </span></span><span class="trans">隐约出现 </span><span class="trans ty_pinyin">yǐnyuē chūxiàn </span></span>
      </span>
    </span>
    <span class="gramb x_xd0 hasSn"><span class="x_xdh"><span class="gp sn ty_label tg_gramb">B.</span><span class="ps">noun </span></span>
      <span class="semb x_xd1"><span class="trg x_xd2"><span class="gl"><span class="gp tg_gl">[</span>尤指远处的<span class="gp tg_gl">] </span></span><span class="trans">微光 </span><span class="trans ty_pinyin">wēiguāng</span></span></span>
      <span class="semb x_xd1"><span class="xrg"><span class="xr">glimmering</span></span></span>
    </span>
    <span class="pvsec x_xo1"><span class="pvg x_xoh"><span class="pv">glimmer out</span></span>
      <span class="gramb x_xo2"><span class="ps">phrasal verb </span><span class="semb x_xo3"><span class="trg x_xo5"><span class="trans">渐渐熄灭 </span></span></span></span>
    </span>
    </d:entry></body></html>
    """

    @Test func parseReadsGroupsSensesAndLabels() throws {
        let entry = try #require(OxfordDictionary.parse(html: glimmer))
        #expect(entry.headword == "glimmer")
        #expect(entry.groups.map(\.pos) == [.verb, .noun])

        // Two targets in one sense are joined; pinyin, collocates and the example are dropped.
        #expect(entry.groups[0].senses == [
            OxfordSense(label: "(shine faintly)", translation: "闪烁、发微光"),
            // Fields come first; the register ("figurative") is dropped.
            OxfordSense(label: "Finance, Law (appear)", translation: "隐约出现"),
        ])
        // A gloss is a label too; the cross-reference-only sense is skipped.
        #expect(entry.groups[1].senses == [OxfordSense(label: "[尤指远处的]", translation: "微光")])
    }

    @Test func parseReturnsNilForStubsAndGarbage() {
        let stub = """
        <html xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng"><body>
        <d:entry id="e_test2" d:title="glimmered" class="entry"><span class="hwg x_xh0"><span class="hw">glimmered</span></span>
        <span class="xrg"><span class="xr">glimmer</span></span></d:entry></body></html>
        """
        #expect(OxfordDictionary.parse(html: stub) == nil)
        #expect(OxfordDictionary.parse(html: "not xml <<<") == nil)
    }

    @Test(arguments: [
        ("transitive verb", SensePicker.POSKind.verb), ("modal verb", .verb), ("adverb", .adverb),
        ("noun", .noun), ("plural noun", .noun), ("pronoun", .pronoun), ("adjective", .adjective),
        ("preposition", .preposition), ("conjunction", .conjunction), ("determiner", .determiner),
        ("exclamation", .other), ("", .other),
    ])
    func posNamesMapToKinds(_ name: String, _ kind: SensePicker.POSKind) {
        #expect(OxfordDictionary.posKind(name) == kind)
    }

    // MARK: - Choosing the entry

    private func entry(_ headword: String, _ groups: (SensePicker.POSKind, String)...) -> OxfordEntry {
        OxfordEntry(headword: headword,
                    groups: groups.map { OxfordGroup(pos: $0.0, senses: [OxfordSense(label: nil, translation: $0.1)]) })
    }

    @Test func exactHeadwordWinsOverItsBaseForm() {
        let entries = [entry("run", (.verb, "跑")), entry("running", (.noun, "跑步"), (.adjective, "连续的"))]
        let group = OxfordDictionary.pick(from: entries, for: "running", preferredPOS: nil)
        #expect(group?.senses.first?.translation == "跑步")
    }

    @Test func contextPOSPicksTheMatchingGroup() {
        let entries = [entry("run", (.verb, "跑")), entry("running", (.noun, "跑步"), (.adjective, "连续的"))]
        // "he was running": the exact entry has no verb group, its base form does.
        #expect(OxfordDictionary.pick(from: entries, for: "running", preferredPOS: .verb)?.senses.first?.translation == "跑")
        #expect(OxfordDictionary.pick(from: entries, for: "running", preferredPOS: .adjective)?.senses.first?.translation == "连续的")
        // No entry has that part of speech → fall back to the first group.
        #expect(OxfordDictionary.pick(from: entries, for: "running", preferredPOS: .adverb)?.senses.first?.translation == "跑步")
    }

    @Test func caseDoesNotMatterForTheExactMatch() {
        let entries = [entry("apple", (.noun, "苹果"))]
        #expect(OxfordDictionary.pick(from: entries, for: "Apple", preferredPOS: nil) != nil)
    }

    @Test func lookAlikesFromTheIndexAreIgnored() {
        // The index returns "bettor" for "better"; a noun context must not land on it.
        let entries = [entry("better", (.adjective, "更好的")), entry("bettor", (.noun, "打赌者"))]
        #expect(OxfordDictionary.pick(from: entries, for: "better", preferredPOS: .noun)?.senses.first?.translation == "更好的")
        #expect(OxfordDictionary.pick(from: [entry("bettor", (.noun, "打赌者"))], for: "better", preferredPOS: nil) == nil)
    }

    @Test(arguments: [("harden", "hardened"), ("analysis", "analyses"), ("leaf", "leaves"), ("run", "running")])
    func baseFormsAreRecognised(_ headword: String, _ word: String) {
        #expect(OxfordDictionary.isBaseForm(headword, of: word, lemma: word))
    }

    @Test func irregularBaseFormNeedsTheLemma() {
        #expect(OxfordDictionary.isBaseForm("go", of: "went", lemma: "go"))
        #expect(!OxfordDictionary.isBaseForm("well", of: "better", lemma: "better"))
    }

    @Test func acronymsGoToECDICTFirst() {
        #expect(OxfordDictionary.prefersECDICT("API"))
        #expect(OxfordDictionary.prefersECDICT("HTTP/2"))
        #expect(!OxfordDictionary.prefersECDICT("Apple"))
        #expect(!OxfordDictionary.prefersECDICT("I"))
        #expect(!OxfordDictionary.prefersECDICT("dismiss"))
    }

    // MARK: - Against the real dictionary (skipped when it isn't enabled on this Mac)

    private static let installed = OxfordDictionary()

    @Test(.enabled(if: installed != nil))
    func realDictionaryGivesLabelledSenses() throws {
        let oxford = try #require(Self.installed)

        let dismiss = try #require(oxford.lookup("dismiss", preferredPOS: nil))
        #expect(dismiss.count == 3)
        #expect(dismiss[0].label == "(reject)")
        #expect(!dismiss[0].translation.isEmpty)
        // No pinyin leaked into the Chinese.
        #expect(dismiss.allSatisfy { !$0.translation.contains(where: { $0.isASCII && $0.isLetter }) })

        // Inflected form + context: "has hardened" resolves to the verb "harden".
        #expect(oxford.lookup("hardened", preferredPOS: .verb) != nil)
        // Not in this dictionary → nil, so the caller falls back to ECDICT.
        #expect(oxford.lookup("idempotent", preferredPOS: nil) == nil)
        #expect(oxford.lookup("", preferredPOS: nil) == nil)
    }
    // MARK: - Popup text (one short line)

    @Test func popupTextKeepsTheFirstRenderingOfEachSenseOnOneLine() {
        let senses = [
            OxfordSense(label: "(shine faintly)", translation: "闪烁、发微光"),
            OxfordSense(label: nil, translation: "微光"),
            OxfordSense(label: "Finance (appear)", translation: "隐约出现"),
        ]
        #expect(OverlayPanel.oxfordText(senses) == "闪烁；微光；隐约出现")
    }

    @Test func popupTextDropsRepeatsAndBlanks() {
        let senses = [
            OxfordSense(label: "(of door)", translation: "把手"),
            OxfordSense(label: "(of tool)", translation: "把手、柄"),
            OxfordSense(label: nil, translation: " "),
        ]
        #expect(OverlayPanel.oxfordText(senses) == "把手")
        #expect(OverlayPanel.oxfordText([]) == "")
    }
    // MARK: - Expanded popup (Shift)

    @Test @MainActor func detailTextListsGroupsWithLabels() {
        let groups = [
            OxfordGroup(pos: .noun, senses: [
                OxfordSense(label: "(shine faintly)", translation: "闪烁、发微光"),
                OxfordSense(label: nil, translation: "隐约出现"),
            ]),
            OxfordGroup(pos: .noun, senses: [OxfordSense(label: nil, translation: "复数义")]),
            OxfordGroup(pos: .verb, senses: [OxfordSense(label: "[尤指远处的]", translation: "微光")]),
        ]
        let text = OverlayPanel.detailText(glossary: "微光（自定义）", groups: groups,
                                           ecdict: "n. 微光").string
        // Same POS in a row → one header; ECDICT left out when Oxford has the word.
        #expect(text == """
        词表  微光（自定义）
        名词
        (shine faintly) 闪烁、发微光
        隐约出现
        复数义
        动词
        [尤指远处的] 微光
        """)
    }

    @Test @MainActor func detailTextGivesEachPOSItsShare() {
        let nouns = OxfordGroup(pos: .noun, senses: (1...9).map { OxfordSense(label: nil, translation: "名\($0)") })
        let verbs = OxfordGroup(pos: .verb, senses: (1...9).map { OxfordSense(label: nil, translation: "动\($0)") })
        let adjs = OxfordGroup(pos: .adjective, senses: (1...9).map { OxfordSense(label: nil, translation: "形\($0)") })
        let lines = OverlayPanel.detailText(glossary: nil, groups: [nouns, verbs, adjs], ecdict: nil).string
            .split(separator: "\n")
        #expect(lines == ["名词", "名1", "名2", "名3", "动词", "动1", "动2", "动3", "形容词", "形1", "形2"])
    }

    @Test @MainActor func detailTextGivesASinglePOSTheWholeBudget() {
        let verbs = OxfordGroup(pos: .verb, senses: (1...9).map { OxfordSense(label: nil, translation: "动\($0)") })
        #expect(OverlayPanel.detailText(glossary: nil, groups: [verbs], ecdict: nil).string
                .split(separator: "\n").count == 9)        // header + 8
    }

    @Test @MainActor func detailTextFallsBackToECDICT() {
        #expect(OverlayPanel.detailText(glossary: nil, groups: nil,
                                        ecdict: "[计] 幂等\n\nadj. 幂等的\n第三行\n第四行").string
                == "[计] 幂等\nadj. 幂等的\n第三行")
        #expect(OverlayPanel.detailText(glossary: nil, groups: nil, ecdict: nil).string == "（未找到释义）")
    }
}

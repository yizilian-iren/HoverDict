import Testing
@testable import HoverDict

@Suite struct SensePickerTests {

    // MARK: - Tagging the context

    @Test func sameWordIsTaggedByItsContext() {
        #expect(SensePicker.lexicalPOS(of: "record", in: "we will record the meeting tomorrow") == .verb)
        #expect(SensePicker.lexicalPOS(of: "record", in: "she broke the world record yesterday") == .noun)
    }

    @Test func inflectedAndPunctuatedTokensStillMatch() {
        #expect(SensePicker.lexicalPOS(of: "running", in: "he was running quickly down the street") == .verb)
        #expect(SensePicker.lexicalPOS(of: "quickly", in: "he was running quickly, then stopped") == .adverb)
    }

    @Test func wordMissingFromThePhraseGivesNil() {
        #expect(SensePicker.lexicalPOS(of: "banana", in: "we will record the meeting") == nil)
        #expect(SensePicker.lexicalPOS(of: "record", in: "") == nil)
        #expect(SensePicker.lexicalPOS(of: "  ", in: "we will record the meeting") == nil)
    }

    // MARK: - ECDICT markers

    @Test func markersCoverTheEcdictSpellings() {
        #expect(SensePicker.ecdictMarkers(for: .verb) == ["v", "vt", "vi", "aux"])
        #expect(SensePicker.ecdictMarkers(for: .noun).contains("n"))
        #expect(SensePicker.ecdictMarkers(for: .adjective).contains("a"))
        #expect(SensePicker.ecdictMarkers(for: .other).isEmpty)
    }

    // MARK: - Picking the translation line (OverlayPanel.collapse)

    private let record = "n. 记录, 唱片, 履历\nvt. 记录, 录音, 标明\nvi. 录音\n[计] 记录"

    @Test func collapseDefaultsToTheFirstPOSLine() {
        #expect(OverlayPanel.collapse(record, maxSenses: 2) == "记录, 唱片")
    }

    @Test func collapsePrefersTheLineMatchingTheContextPOS() {
        #expect(OverlayPanel.collapse(record, maxSenses: 3, preferredPOS: .verb) == "记录, 录音, 标明")
        #expect(OverlayPanel.collapse(record, maxSenses: 3, preferredPOS: .noun) == "记录, 唱片, 履历")
    }

    @Test func collapseFallsBackWhenNoLineMatches() {
        #expect(OverlayPanel.collapse(record, maxSenses: 1, preferredPOS: .adverb) == "记录")
        #expect(OverlayPanel.collapse(record, maxSenses: 1, preferredPOS: .other) == "记录")
    }

    @Test func collapseSkipsDomainTagsAndSplitsChineseCommas() {
        #expect(OverlayPanel.collapse("[医] 苹果\nn. 苹果，家伙、珍宝", maxSenses: 3) == "苹果, 家伙, 珍宝")
        #expect(OverlayPanel.collapse("苹果公司", maxSenses: 2) == "苹果公司")
        #expect(OverlayPanel.collapse("", maxSenses: 2) == "")
    }

    @Test func collapseKeepsAtLeastOneSense() {
        #expect(OverlayPanel.collapse(record, maxSenses: 0) == "记录")
    }
}

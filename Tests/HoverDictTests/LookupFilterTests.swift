import Testing
@testable import HoverDict

@Suite struct LookupFilterTests {

    // MARK: - Numbers

    @Test(arguments: ["123", "3.14", "50%", "$12", "1st", "21st", "2024-08-20", "16:9", "1,000", "#42"])
    func numericTokens(_ token: String) {
        #expect(LookupFilter.isNumericToken(token))
    }

    @Test(arguments: ["apple", "v2", "h264", "x", "", "..."])
    func nonNumericTokens(_ token: String) {
        #expect(!LookupFilter.isNumericToken(token))
    }

    @Test func numbersInProseAreSkipped() {
        let words = prose("the report lists 2024 figures for comparison")
        #expect(LookupFilter.shouldSkip(words.hit("2024"), in: words, fromClick: false))
    }

    // MARK: - Words in prose

    @Test(arguments: ["report", "figures", "comparison"])
    func contentWordsInProseAreLookedUp(_ word: String) {
        let words = prose("the report lists 2024 figures for comparison")
        #expect(!LookupFilter.shouldSkip(words.hit(word), in: words, fromClick: false))
        #expect(!LookupFilter.shouldSkip(words.hit(word), in: words, fromClick: true))
    }

    @Test(arguments: ["the", "for", "is"])
    func basicWordsAreSkippedEvenInProse(_ word: String) {
        let words = prose("Thinking the model is ready for deployment")
        #expect(LookupFilter.shouldSkip(words.hit(word), in: words, fromClick: false))
    }

    // MARK: - Status lines

    @Test(arguments: ["Thinking", "analyzing", "reasoning", "considering", "streaming"])
    func statusWordsInsideASentenceAreLookedUp(_ word: String) {
        let words = prose("Thinking about analyzing the reasoning behind considering streaming responses")
        #expect(!LookupFilter.shouldSkip(words.hit(word), in: words, fromClick: false))
        #expect(!LookupFilter.shouldSkip(words.hit(word), in: words, fromClick: true))
    }

    @Test func isolatedStatusLineIsSkipped() {
        let alone = line(["Thinking…"])
        #expect(LookupFilter.shouldSkip(alone[0], in: alone, fromClick: false))

        let withDetail = line(["Searching", "the", "web"])
        #expect(LookupFilter.shouldSkip(withDetail.hit("Searching"), in: withDetail, fromClick: false))
        #expect(LookupFilter.shouldSkip(withDetail.hit("web"), in: withDetail, fromClick: false))
    }

    @Test func shortLineEndingInAStatusWordIsLookedUp() {
        // Only a line that STARTS with a status word reads as a status indicator.
        let words = line(["deductive", "reasoning"])
        #expect(!LookupFilter.shouldSkip(words.hit("reasoning"), in: words, fromClick: false))
        #expect(!LookupFilter.shouldSkip(words.hit("deductive"), in: words, fromClick: false))
    }

    @Test func trailingPunctuationDoesNotHideAWord() {
        let words = prose("please read the following paragraph, carefully.")
        #expect(!LookupFilter.shouldSkip(words.hit("paragraph,"), in: words, fromClick: false))
        #expect(!LookupFilter.shouldSkip(words.hit("carefully."), in: words, fromClick: false))
    }

    @Test func uiLabelWordInsideASentenceIsLookedUp() {
        let words = prose("please send it before the deadline")
        #expect(!LookupFilter.shouldSkip(words.hit("send"), in: words, fromClick: false))
    }

    @Test func titleCaseWordInsideASentenceIsLookedUpOnClick() {
        let words = prose("yesterday Settings moved somewhere unexpected")
        #expect(!LookupFilter.shouldSkip(words.hit("Settings"), in: words, fromClick: true))
    }

    // MARK: - Single letters, CJK

    @Test(arguments: ["X", "Q", "a", "I", "—", ""])
    func singleLettersAndPunctuationAreSkipped(_ token: String) {
        let words = prose("press \(token) quickly whenever possible")
        let hit = WordHit(text: token, globalRect: words[1].globalRect)
        #expect(LookupFilter.shouldSkip(hit, in: words, fromClick: false))
    }

    @Test(arguments: ["你好", "勉強する", "ひらがな"])
    func cjkTokensAreSkippedOnTheEnglishPath(_ token: String) {
        let words = line([token])
        #expect(LookupFilter.shouldSkip(words[0], in: words, fromClick: false))
    }

    // MARK: - Buttons / chrome

    @Test(arguments: ["Send", "Cancel", "Settings", "OK"])
    func isolatedKnownLabelIsSkipped(_ label: String) {
        let words = line([label])
        #expect(LookupFilter.shouldSkip(words[0], in: words, fromClick: false))
    }

    @Test func isolatedLabelFarFromProseIsSkipped() {
        // A button 60pt to the right of a sentence on the same line.
        let words = line(["quarterly", "revenue", "estimate", "Send"], gaps: [0, 6, 6, 60])
        #expect(LookupFilter.shouldSkip(words.hit("Send"), in: words, fromClick: false))
        #expect(!LookupFilter.shouldSkip(words.hit("revenue"), in: words, fromClick: false))
    }

    @Test(arguments: ["Dismiss", "Discard", "Snooze", "Decline", "Subscribe", "Preview"])
    func isolatedButtonWordALearnerMayNotKnowIsLookedUpOnHover(_ label: String) {
        let words = line([label])
        #expect(!LookupFilter.shouldSkip(words[0], in: words, fromClick: false))
    }

    @Test func headingsAndAllCapsAreLookedUpOnHoverButNotOnClick() {
        let caps = line(["DEPRECATED"])
        #expect(!LookupFilter.shouldSkip(caps[0], in: caps, fromClick: false))
        #expect(LookupFilter.shouldSkip(caps[0], in: caps, fromClick: true))

        let heading = line(["Hardened", "Runtime"])
        #expect(!LookupFilter.shouldSkip(heading.hit("Hardened"), in: heading, fromClick: false))
        #expect(!LookupFilter.shouldSkip(heading.hit("Runtime"), in: heading, fromClick: false))
        #expect(LookupFilter.shouldSkip(heading.hit("Hardened"), in: heading, fromClick: true))
    }

    @Test func elementaryLabelNextToAnotherWordIsStillSkipped() {
        let words = line(["New", "Chat"])
        #expect(LookupFilter.shouldSkip(words.hit("Chat"), in: words, fromClick: false))
    }

    @Test func isolatedTitleCaseWordDependsOnClick() {
        // Hovering a lone heading word looks it up; clicking it is a button press.
        let words = line(["Bold"])
        #expect(!LookupFilter.shouldSkip(words[0], in: words, fromClick: false))
        #expect(LookupFilter.shouldSkip(words[0], in: words, fromClick: true))
    }

    @Test func isolatedLowercaseWordIsLookedUp() {
        let words = line(["ephemeral"])
        #expect(!LookupFilter.shouldSkip(words[0], in: words, fromClick: false))
        #expect(!LookupFilter.shouldSkip(words[0], in: words, fromClick: true))
    }

    @Test func wordsOnOtherLinesDoNotCountAsProse() {
        let button = line(["Send"], y: 500)
        let paragraph = prose("an unrelated paragraph sits well above it", y: 560)
        #expect(LookupFilter.shouldSkip(button[0], in: button + paragraph, fromClick: false))
    }

    // MARK: - Japanese

    @Test(arguments: ["は", "の", "です", "から", "する", "これ"])
    func japaneseFunctionWordsAreSkipped(_ term: String) {
        #expect(LookupFilter.shouldSkipJapanese(term))
    }

    @Test(arguments: ["たべる", "勉強", "コーヒー", "食べる"])
    func japaneseContentWordsAreKept(_ term: String) {
        #expect(!LookupFilter.shouldSkipJapanese(term))
    }
}

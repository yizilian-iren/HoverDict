import CoreGraphics
import Testing
@testable import HoverDict

@Suite struct CoordinateMapperTests {

    // MARK: - Vision box → screen

    @Test func normalizedBoxScalesLinearlyIntoTheCaptureRect() {
        let capture = CGRect(x: 1000, y: 400, width: 260, height: 100)
        let box = CGRect(x: 0.5, y: 0.25, width: 0.1, height: 0.2)
        let rect = CoordinateMapper.globalRect(forNormalizedBox: box, captureRectGlobal: capture)
        #expect(rect == CGRect(x: 1130, y: 425, width: 26, height: 20))
    }

    @Test func captureRectOnASecondaryDisplayKeepsNegativeOrigin() {
        let capture = CGRect(x: -1920, y: -200, width: 200, height: 100)
        let rect = CoordinateMapper.globalRect(forNormalizedBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                                               captureRectGlobal: capture)
        #expect(rect == capture)
    }

    @Test func resolveKeepsTextAndOrder() {
        let capture = CGRect(x: 0, y: 0, width: 100, height: 100)
        let hits = CoordinateMapper.resolve(
            words: [RecognizedWord(text: "alpha", normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)),
                    RecognizedWord(text: "beta", normalizedBox: CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.1))],
            captureRectGlobal: capture)
        #expect(hits.map(\.text) == ["alpha", "beta"])
        #expect(hits[1].globalRect.minX == 40)
    }

    // MARK: - Hit test

    /// Two lines: "alpha beta" at y 500…514 and "gamma" directly below at y 480…494.
    private var twoLines: [WordHit] {
        line(["alpha", "beta"], y: 500) + line(["gamma"], y: 480)
    }

    @Test func cursorOnAWordHitsIt() {
        let words = twoLines
        let beta = words.hit("beta").globalRect
        let hit = CoordinateMapper.wordUnderCursor(words, cursorGlobal: CGPoint(x: beta.midX, y: beta.midY))
        #expect(hit?.text == "beta")
    }

    @Test func cursorBetweenWordsHitsNothing() {
        let words = twoLines
        let alpha = words.hit("alpha").globalRect
        // The word space is 6pt wide; its middle is outside both boxes' 1pt slop.
        let hit = CoordinateMapper.wordUnderCursor(words, cursorGlobal: CGPoint(x: alpha.maxX + 3, y: alpha.midY))
        #expect(hit == nil)
    }

    @Test func cursorJustAboveAWordStillHitsIt() {
        let words = twoLines
        let alpha = words.hit("alpha").globalRect
        let above = CoordinateMapper.wordUnderCursor(words, cursorGlobal: CGPoint(x: alpha.midX, y: alpha.maxY + 5))
        #expect(above?.text == "alpha")
        let tooFar = CoordinateMapper.wordUnderCursor(words, cursorGlobal: CGPoint(x: alpha.midX, y: alpha.maxY + 7))
        #expect(tooFar == nil)
    }

    @Test func cursorBelowAWordDoesNotHitIt() {
        let words = line(["alpha"], y: 500)
        let alpha = words[0].globalRect
        let hit = CoordinateMapper.wordUnderCursor(words, cursorGlobal: CGPoint(x: alpha.midX, y: alpha.minY - 1))
        #expect(hit == nil)
    }

    @Test func cursorInTheGapBetweenLinesPicksTheLineBelow() {
        // y 497 is in the 6pt gap between the lines: within "gamma"'s top margin (494 + 6)
        // and below "alpha"'s bottom (500), so only the lower line qualifies.
        let words = twoLines
        let gamma = words.hit("gamma").globalRect
        let hit = CoordinateMapper.wordUnderCursor(words, cursorGlobal: CGPoint(x: gamma.midX, y: 497))
        #expect(hit?.text == "gamma")
    }

    @Test func overlappingLinesPickTheNearerVerticalCenter() {
        // Tight line spacing: at y 501 the cursor is inside "alpha" (500…514) and inside
        // the top margin of "gamma" (486…500, +6). "alpha"'s center (507) is 6 away,
        // "gamma"'s (493) is 8 away.
        let words = line(["alpha"], y: 500) + line(["gamma"], y: 486)
        let hit = CoordinateMapper.wordUnderCursor(words, cursorGlobal: CGPoint(x: 110, y: 501))
        #expect(hit?.text == "alpha")
    }

    @Test func noWordsHitsNothing() {
        #expect(CoordinateMapper.wordUnderCursor([], cursorGlobal: .zero) == nil)
        #expect(CoordinateMapper.japaneseTarget(in: [], captureRectGlobal: .zero, cursorGlobal: .zero) == nil)
    }

    // MARK: - Context phrase

    @Test func contextPhraseIsTheSameLineInReadingOrder() {
        let top = prose("we record the meeting", y: 500)
        let bottom = prose("something else entirely", y: 470)
        // Shuffled input: OCR order is not guaranteed.
        let words = bottom + top.reversed()
        #expect(CoordinateMapper.contextPhrase(around: top.hit("record"), in: words) == "we record the meeting")
    }

    @Test func contextPhraseIsLimitedToTheWindow() {
        let words = prose("one two three four five six seven eight nine")
        let phrase = CoordinateMapper.contextPhrase(around: words.hit("five"), in: words, window: 2)
        #expect(phrase == "three four five six seven")
    }

    @Test func contextPhraseFallsBackToTheWordItself() {
        let stray = WordHit(text: "stray", globalRect: CGRect(x: 0, y: 0, width: 35, height: 14))
        #expect(CoordinateMapper.contextPhrase(around: stray, in: prose("an unrelated line")) == "stray")
    }
}

extension WordHit: Equatable {
    public static func == (a: WordHit, b: WordHit) -> Bool {
        a.text == b.text && a.globalRect == b.globalRect
    }
}

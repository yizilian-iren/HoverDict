import CoreGraphics
@testable import HoverDict

/// Lays words out left to right on one line, the way OCR would report them.
/// `gaps[i]` is the space before word `i` (default 6pt — a normal word space);
/// each character is 7pt wide and the line is 14pt tall.
func line(_ texts: [String],
          gaps: [CGFloat] = [],
          x: CGFloat = 100,
          y: CGFloat = 500) -> [WordHit] {
    var hits: [WordHit] = []
    var cursor = x
    for (i, text) in texts.enumerated() {
        cursor += i < gaps.count ? gaps[i] : (i == 0 ? 0 : 6)
        let width = CGFloat(text.count) * 7
        hits.append(WordHit(text: text, globalRect: CGRect(x: cursor, y: y, width: width, height: 14)))
        cursor += width
    }
    return hits
}

/// A sentence long enough that no word in it is an isolated label.
func prose(_ sentence: String, y: CGFloat = 500) -> [WordHit] {
    line(sentence.split(separator: " ").map(String.init), y: y)
}

extension Array where Element == WordHit {
    /// The hit for `text` (first match).
    func hit(_ text: String) -> WordHit {
        first { $0.text == text }!
    }
}

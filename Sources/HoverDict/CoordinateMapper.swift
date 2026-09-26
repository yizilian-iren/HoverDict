import AppKit
import CoreGraphics

/// A recognized word resolved into AppKit **global screen coordinates**
/// (points, bottom-left origin) — ready for hit-testing and panel placement.
struct WordHit {
    let text: String
    /// Global screen rect, points, bottom-left origin.
    let globalRect: CGRect
}

/// Coordinate conversion + hit testing. This is historically the buggiest part of
/// any take-word tool, so every transform is spelled out.
///
/// Coordinate systems in play:
///   • Vision box: normalized (0...1), origin **bottom-left** of the captured image.
///   • AppKit global screen: points, origin **bottom-left** of the primary display
///     (same space as `NSEvent.mouseLocation` and `NSWindow.setFrameOrigin`).
///
/// Key realization: the top/bottom Y-flip and the Retina pixel scaling were *already*
/// handled when we built `SCStreamConfiguration.sourceRect` (in ScreenCapturer). The
/// captured image therefore covers exactly `captureRectGlobal`, and BOTH Vision and
/// AppKit use a bottom-left origin. So converting a Vision box back to global screen
/// space is a straight linear scale — no extra flip, no scale factor here.
enum CoordinateMapper {

    /// Vision normalized box (bottom-left) → AppKit global screen rect (bottom-left, points).
    static func globalRect(forNormalizedBox box: CGRect, captureRectGlobal: CGRect) -> CGRect {
        let x = captureRectGlobal.minX + box.minX * captureRectGlobal.width
        let y = captureRectGlobal.minY + box.minY * captureRectGlobal.height
        let w = box.width * captureRectGlobal.width
        let h = box.height * captureRectGlobal.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Resolve every recognized word into global coordinates.
    static func resolve(words: [RecognizedWord], captureRectGlobal: CGRect) -> [WordHit] {
        words.map {
            WordHit(text: $0.text,
                    globalRect: globalRect(forNormalizedBox: $0.normalizedBox,
                                           captureRectGlobal: captureRectGlobal))
        }
    }

    /// Hit test: find the word **directly under** the cursor (strict mode — returns
    /// nil if nothing qualifies, so the panel stays hidden over empty space).
    ///
    /// Why a small upward `topMargin`: people hover with the pointer *tip* resting on,
    /// or a hair above, the top of a word. So a word counts as "under the cursor" when
    /// the cursor is horizontally inside its box and vertically within the box extended
    /// slightly upward (in bottom-left space, "up" = larger Y, i.e. past `maxY`).
    /// Among qualifying words we pick the one whose vertical center is closest to the
    /// cursor, which naturally selects the single line the pointer is resting on.
    static func wordUnderCursor(_ words: [WordHit],
                                cursorGlobal: CGPoint,
                                topMargin: CGFloat = 6,
                                horizontalSlop: CGFloat = 1) -> WordHit? {
        var best: WordHit?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for hit in words {
            let box = hit.globalRect
            let horizontallyInside = cursorGlobal.x >= box.minX - horizontalSlop
                                  && cursorGlobal.x <= box.maxX + horizontalSlop
            // Vertically: from the word's bottom up to its top edge plus a small margin.
            let verticallyInside = cursorGlobal.y >= box.minY
                                && cursorGlobal.y <= box.maxY + topMargin
            guard horizontallyInside, verticallyInside else { continue }

            let distance = abs(cursorGlobal.y - box.midY)
            if distance < bestDistance {
                bestDistance = distance
                best = hit
            }
        }
        return best
    }

    /// Japanese hit test: the line under the cursor, and the UTF-16 offset of the character
    /// the cursor sits on (DictionaryServices then finds the word around that offset).
    ///
    /// Returns nil unless the line contains kana — a pure-kanji line is far more likely
    /// Chinese (our user reads Chinese natively), so it is left alone.
    static func japaneseTarget(in lines: [RecognizedLine],
                               captureRectGlobal: CGRect,
                               cursorGlobal: CGPoint,
                               topMargin: CGFloat = 6) -> (line: String, utf16Offset: Int)? {
        var bestLine: RecognizedLine?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for line in lines {
            let box = globalRect(forNormalizedBox: line.normalizedBox, captureRectGlobal: captureRectGlobal)
            guard cursorGlobal.x >= box.minX, cursorGlobal.x <= box.maxX,
                  cursorGlobal.y >= box.minY, cursorGlobal.y <= box.maxY + topMargin else { continue }
            let distance = abs(cursorGlobal.y - box.midY)
            if distance < bestDistance {
                bestDistance = distance
                bestLine = line
            }
        }
        guard let line = bestLine, JapaneseText.containsKana(line.text) else { return nil }

        // Per-character boxes: pick the character whose box contains (or is nearest to)
        // the cursor horizontally.
        let text = line.text
        var bestChar: (index: String.Index, distance: CGFloat)?
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if let obs = try? line.candidate.boundingBox(for: i..<next) {
                let box = globalRect(forNormalizedBox: obs.boundingBox, captureRectGlobal: captureRectGlobal)
                let distance = cursorGlobal.x < box.minX ? box.minX - cursorGlobal.x
                             : cursorGlobal.x > box.maxX ? cursorGlobal.x - box.maxX
                             : 0
                if bestChar == nil || distance < bestChar!.distance {
                    bestChar = (i, distance)
                }
            }
            i = next
        }
        guard let hit = bestChar, hit.distance <= 2, JapaneseText.isJapanese(text[hit.index]) else {
            return nil
        }
        return (text, text.utf16.distance(from: text.startIndex, to: hit.index))
    }

    /// Nearby words on the same visual line as `target`, joined into a short phrase
    /// for POS tagging (±`window` tokens). Falls back to the bare word if nothing
    /// else shares the line.
    static func contextPhrase(around target: WordHit,
                              in words: [WordHit],
                              window: Int = 5,
                              lineSlop: CGFloat = 8) -> String {
        let sameLine = words
            .filter { abs($0.globalRect.midY - target.globalRect.midY) <= lineSlop }
            .sorted { $0.globalRect.minX < $1.globalRect.minX }

        guard let idx = sameLine.firstIndex(where: {
            $0.text == target.text
                && abs($0.globalRect.midX - target.globalRect.midX) < 0.5
                && abs($0.globalRect.midY - target.globalRect.midY) < 0.5
        }) else {
            return target.text
        }

        let start = max(0, idx - window)
        let end = min(sameLine.count - 1, idx + window)
        return sameLine[start...end].map(\.text).joined(separator: " ")
    }
}

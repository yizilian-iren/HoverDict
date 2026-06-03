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
}

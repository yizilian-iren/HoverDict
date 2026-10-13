import Foundation
import Vision
import CoreGraphics

/// A single recognized word and its bounding box, **normalized** (0...1) within the
/// captured image, using Vision's convention: origin at the image's **bottom-left**.
struct RecognizedWord {
    let text: String
    let normalizedBox: CGRect
}

/// A whole recognized line. Japanese has no spaces, so the Japanese path hit-tests
/// per character on the line and lets the dictionary decide where the word ends.
struct RecognizedLine {
    let text: String
    let normalizedBox: CGRect
    /// Kept so per-character boxes can be requested lazily for the one line under the cursor.
    let candidate: VNRecognizedText
}

struct OCRResult {
    let words: [RecognizedWord]
    let lines: [RecognizedLine]
}

/// Runs Vision text recognition on a captured image and returns per-word boxes.
final class OCRService {

    /// Called on the main thread when a recognition pass hangs and cancelling it didn't
    /// free it. Vision can wedge for good (seen 2026-10-13: VNRecognizeTextRequest waiting
    /// on a semaphore for hours), and every later lookup is then dropped behind it.
    var onStuck: (() -> Void)?

    /// How long a pass may run before it is cancelled. Japanese is longer: its model's
    /// first load takes ~17 s.
    private static let englishLimit: TimeInterval = 6
    private static let japaneseLimit: TimeInterval = 30
    /// After cancelling, how long to wait for the pass to return before giving up on it.
    private static let cancelGrace: TimeInterval = 3

    /// The ja-JP model takes ~17 s to load the first time a new build runs it (then it is
    /// cached). Run one blank pass at launch so the first real hover isn't stuck on that.
    func warmUpJapanese() {
        guard let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let blank = ctx.makeImage() else { return }
        _ = recognize(in: blank, includeJapanese: true)
    }

    /// `includeJapanese` adds ja-JP (which also reads Latin text); off → English only.
    func recognize(in image: CGImage, includeJapanese: Bool) -> OCRResult {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate          // spec: accuracy = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = includeJapanese ? ["ja-JP", "en-US"] : ["en-US"]

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let finished = Flag()
        defer { finished.set() }
        watch(request, finished: finished,
              limit: includeJapanese ? Self.japaneseLimit : Self.englishLimit)
        do {
            try handler.perform([request])
        } catch {
            NSLog("HoverDict: OCR failed: \(error)")
            return OCRResult(words: [], lines: [])
        }

        guard let observations = request.results else { return OCRResult(words: [], lines: []) }

        var words: [RecognizedWord] = []
        var lines: [RecognizedLine] = []
        for observation in observations {
            // Each observation is a recognized *line*. Take the best candidate and
            // split it into words, asking Vision for each word's tight box.
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string
            lines.append(RecognizedLine(text: string,
                                        normalizedBox: observation.boundingBox,
                                        candidate: candidate))

            for range in wordRanges(in: string) {
                // boundingBox(for:) maps a substring range back to image coordinates.
                // It returns a VNRectangleObservation whose .boundingBox is normalized
                // (0...1), bottom-left origin.
                guard let rectObservation = try? candidate.boundingBox(for: range) else { continue }
                let box = rectObservation.boundingBox
                let word = String(string[range])
                guard !word.isEmpty else { continue }
                words.append(RecognizedWord(text: word, normalizedBox: box))
            }
        }
        return OCRResult(words: words, lines: lines)
    }

    /// Cancel `request` if it is still running after `limit`; if it still hasn't returned
    /// `cancelGrace` later, report it as stuck.
    private func watch(_ request: VNRequest, finished: Flag, limit: TimeInterval) {
        nonisolated(unsafe) let request = request
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [weak self] in
            guard !finished.isSet else { return }
            NSLog("HoverDict: OCR ran past \(Int(limit)) s; cancelling it")
            request.cancel()
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.cancelGrace) {
                guard !finished.isSet else { return }
                NSLog("HoverDict: OCR still stuck after cancelling")
                DispatchQueue.main.async { self?.onStuck?() }
            }
        }
    }

    /// Split a string into word ranges using the Unicode-aware word enumerator,
    /// so punctuation and whitespace are handled correctly.
    private func wordRanges(in string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        string.enumerateSubstrings(in: string.startIndex..<string.endIndex,
                                   options: [.byWords, .localized]) { _, range, _, _ in
            ranges.append(range)
        }
        return ranges
    }
}

/// A thread-safe one-way switch: has the recognition pass returned yet?
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

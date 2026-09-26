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

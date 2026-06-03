import Foundation
import Vision
import CoreGraphics

/// A single recognized word and its bounding box, **normalized** (0...1) within the
/// captured image, using Vision's convention: origin at the image's **bottom-left**.
struct RecognizedWord {
    let text: String
    let normalizedBox: CGRect
}

/// Runs Vision text recognition on a captured image and returns per-word boxes.
final class OCRService {

    func recognizeWords(in image: CGImage) -> [RecognizedWord] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate          // spec: accuracy = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]      // Phase 1: English only

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("HoverDict: OCR failed: \(error)")
            return []
        }

        guard let observations = request.results else { return [] }

        var words: [RecognizedWord] = []
        for observation in observations {
            // Each observation is a recognized *line*. Take the best candidate and
            // split it into words, asking Vision for each word's tight box.
            guard let candidate = observation.topCandidates(1).first else { continue }
            let string = candidate.string

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
        return words
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

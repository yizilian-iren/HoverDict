import Foundation
import NaturalLanguage

/// Lightweight offline sense picking: tag the OCR context with NaturalLanguage,
/// then prefer the ECDICT translation line whose POS marker matches.
enum SensePicker {

    /// Coarse lexical class used to match ECDICT markers (n. / vt. / a. …).
    enum POSKind: Hashable {
        case noun
        case verb
        case adjective
        case adverb
        case preposition
        case conjunction
        case pronoun
        case determiner
        case number
        case other
    }

    /// Tag `word` inside `phrase` and return its lexical class.
    /// When the word appears more than once, prefer the occurrence closest to
    /// the middle of the phrase (our context window centers the target).
    static func lexicalPOS(of word: String, in phrase: String) -> POSKind? {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedWord.isEmpty, !phrase.isEmpty else { return nil }

        let lemma = DictionaryService.lemmatize(trimmedWord)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = phrase

        let full = phrase.startIndex..<phrase.endIndex
        let center = phrase.distance(from: phrase.startIndex,
                                     to: phrase.index(phrase.startIndex,
                                                      offsetBy: phrase.count / 2))

        var best: (kind: POSKind, distance: Int)?
        tagger.enumerateTags(in: full, unit: .word, scheme: .lexicalClass) { tag, range in
            let token = String(phrase[range])
                .trimmingCharacters(in: .punctuationCharacters)
            guard !token.isEmpty else { return true }

            let matches = token.caseInsensitiveCompare(trimmedWord) == .orderedSame
                || token.caseInsensitiveCompare(lemma) == .orderedSame
            guard matches else { return true }

            let tokenCenter = phrase.distance(from: phrase.startIndex, to: range.lowerBound)
                + phrase.distance(from: range.lowerBound, to: range.upperBound) / 2
            let distance = abs(tokenCenter - center)
            let kind = mapNLTag(tag)
            if best == nil || distance < best!.distance {
                best = (kind, distance)
            }
            return true
        }
        return best?.kind
    }

    /// ECDICT leading markers (lowercase, without the trailing dot) that belong
    /// to `kind`. Used to pick the matching translation line.
    static func ecdictMarkers(for kind: POSKind) -> Set<String> {
        switch kind {
        case .noun:        return ["n", "pl"]
        case .verb:        return ["v", "vt", "vi", "aux"]
        case .adjective:   return ["a", "adj"]
        case .adverb:      return ["ad", "adv"]
        case .preposition: return ["prep"]
        case .conjunction: return ["conj"]
        case .pronoun:     return ["pron"]
        case .determiner:  return ["art"]
        case .number:      return ["num"]
        case .other:       return []
        }
    }

    private static func mapNLTag(_ tag: NLTag?) -> POSKind {
        guard let tag else { return .other }
        switch tag {
        case .noun:         return .noun
        case .verb:         return .verb
        case .adjective:    return .adjective
        case .adverb:       return .adverb
        case .preposition:  return .preposition
        case .conjunction:  return .conjunction
        case .pronoun:      return .pronoun
        case .determiner:   return .determiner
        case .number:       return .number
        default:            return .other
        }
    }
}

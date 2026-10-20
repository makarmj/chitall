import Foundation

/// The word or short phrase to look up in the system dictionary ("Значение"), cleaned of what
/// books add around words: quotes, punctuation, dashes, footnote numbers, stress marks and
/// soft hyphens. A dictionary has no entry for «пищаль,» or "приво́лье", only for the word.
public enum LookupTerm {
    /// Longer selections are a sentence, not a dictionary term.
    public static let maximumWords = 4
    public static let maximumLength = 64

    /// Combining stress marks, soft hyphens and invisible joiners inside words.
    private static let invisible: Set<Unicode.Scalar> = [
        "\u{0300}", "\u{0301}", "\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
    ]

    /// The term to look up, or `nil` when the selection is not a word or a short phrase.
    public static func make(from selection: String) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in selection.unicodeScalars where !invisible.contains(scalar) {
            scalars.append(scalar.properties.isWhitespace ? " " : scalar)
        }
        // Footnote numbers glued to a word: "печатью.[2]".
        let text = String(scalars).replacingOccurrences(of: #"[\[{]\d{1,4}[\]}]"#, with: "", options: .regularExpression)
        let words = text.split(separator: " ").map { trimmed(String($0)) }.filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= maximumWords else { return nil }
        let term = words.joined(separator: " ")
        guard term.count <= maximumLength, term.unicodeScalars.contains(where: \.properties.isAlphabetic) else { return nil }
        return term
    }

    /// Without punctuation, quotes and symbols at either end; a hyphen inside ("из-за") stays.
    private static func trimmed(_ word: String) -> String {
        let scalars = Array(word.unicodeScalars)
        let isWordScalar: (Unicode.Scalar) -> Bool = { $0.properties.isAlphabetic || $0.properties.numericType != nil }
        guard let first = scalars.firstIndex(where: isWordScalar), let last = scalars.lastIndex(where: isWordScalar) else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[first...last])
        return String(view)
    }
}

/// A thought dictated by voice, joined to what is already written: the new words never
/// replace the old ones, and each dictation reads as its own sentence.
public enum DictationText {
    /// `existing` with `dictated` appended. Called again with the growing transcript while
    /// the reader speaks, always with the same `existing`, so nothing is doubled.
    public static func merge(_ existing: String, _ dictated: String) -> String {
        let spoken = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return existing }
        let kept = String(existing.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        guard let last = kept.last else { return capitalized(spoken) }
        if last.isNewline { return kept + capitalized(spoken) }
        if ".!?…".contains(last) { return kept + " " + capitalized(spoken) }
        if last.isLetter || last.isNumber || "»\")".contains(last) { return kept + ". " + capitalized(spoken) }
        // After a comma, a colon or a dash the sentence goes on.
        return kept + " " + spoken
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

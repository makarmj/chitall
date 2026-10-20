import Foundation

/// Where the words of a text start, in UTF-16 offsets (the display coordinates of a chapter),
/// so "how many words are left from here" is a binary search, not a scan on every scroll.
public struct WordIndex: Sendable, Equatable {
    /// UTF-16 offset of the first character of every word, ascending.
    public let starts: [Int]

    public init(_ string: String) {
        var starts: [Int] = []
        var offset = 0
        var inWord = false
        for scalar in string.unicodeScalars {
            let isWordCharacter = scalar.properties.isAlphabetic || scalar.properties.numericType != nil
            if isWordCharacter, !inWord { starts.append(offset) }
            inWord = isWordCharacter
            offset += scalar.utf16.count
        }
        self.starts = starts
    }

    public var count: Int { starts.count }

    /// Words that start inside `range`.
    public func words(in range: Range<Int>) -> Int {
        max(0, firstIndex(atOrAfter: range.upperBound) - firstIndex(atOrAfter: range.lowerBound))
    }

    /// Words that start at `offset` or later.
    public func words(from offset: Int) -> Int {
        starts.count - firstIndex(atOrAfter: offset)
    }

    private func firstIndex(atOrAfter offset: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// The reader's own reading speed, learnt on the device from page turns and scrolling.
/// Until enough has been read it leans on a calm default, so the first estimates are sane.
public struct ReadingPace: Codable, Sendable, Equatable {
    /// A slow, attentive pace for non-fiction in Russian.
    public static let defaultWordsPerMinute = 150.0
    /// Faster means skimming or a jump, slower means a pause: neither is reading speed.
    public static let plausibleWordsPerMinute: ClosedRange<Double> = 40...700
    /// After about this many words the pace follows the reader's recent reading.
    static let memoryWords = 2000
    /// Words to read before the measured pace fully replaces the default.
    static let calibrationWords = 300

    public private(set) var wordsPerMinute: Double
    public private(set) var measuredWords: Int

    public init(wordsPerMinute: Double = ReadingPace.defaultWordsPerMinute, measuredWords: Int = 0) {
        self.wordsPerMinute = wordsPerMinute
        self.measuredWords = measuredWords
    }

    /// Folds in a stretch of reading. Returns `false` (and changes nothing) for a stretch that
    /// is too short or not plausible as reading: a jump, skimming, or a pause.
    @discardableResult
    public mutating func record(words: Int, seconds: Double) -> Bool {
        guard words >= 20, seconds >= 3 else { return false }
        let sample = Double(words) / seconds * 60
        guard Self.plausibleWordsPerMinute.contains(sample) else { return false }
        // An average over everything read at first, then a moving average over ~2000 words.
        let weight = min(1, Double(words) / Double(min(measuredWords + words, Self.memoryWords)))
        if measuredWords == 0 {
            wordsPerMinute = sample
        } else {
            wordsPerMinute += weight * (sample - wordsPerMinute)
        }
        measuredWords += words
        return true
    }

    /// The pace used for estimates: the default blended into the measured one while learning.
    public var effectiveWordsPerMinute: Double {
        guard measuredWords < Self.calibrationWords else { return wordsPerMinute }
        let share = Double(measuredWords) / Double(Self.calibrationWords)
        return Self.defaultWordsPerMinute * (1 - share) + wordsPerMinute * share
    }

    /// Whole minutes to read `words`, rounded up; 0 only when nothing is left.
    public func minutes(forWords words: Int) -> Int {
        guard words > 0 else { return 0 }
        return max(1, Int((Double(words) / effectiveWordsPerMinute).rounded(.up)))
    }

    /// "≈ 6 мин до конца главы", or `nil` at the end of the chapter.
    public func chapterLeftLabel(words: Int) -> String? {
        let minutes = minutes(forWords: words)
        guard minutes > 0 else { return nil }
        return "≈ \(minutes) мин до конца главы"
    }
}

/// The few lines shown in "Где я остановился": the last words read before the saved place.
public enum ResumeSnippet {
    /// Whole words, at most about `limit` characters, starting at a sentence when one starts
    /// near the beginning; "…" marks a cut. `nil` when there is nothing before the place.
    public static func make(from textBefore: String, limit: Int = 220) -> String? {
        let words = textBefore.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return nil }
        var kept: [Substring] = []
        var length = 0
        for word in words.reversed() {
            let added = word.count + (kept.isEmpty ? 0 : 1)
            if length + added > limit, !kept.isEmpty { break }
            kept.insert(word, at: 0)
            length += added
        }
        guard kept.count < words.count else { return kept.joined(separator: " ") }
        // Cut: begin after the first sentence end in the first half, so the card reads naturally.
        let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
        let half = kept.count / 2
        if let end = kept.prefix(half).firstIndex(where: { word in
            guard let last = word.last(where: { !"»\"”)".contains($0) }) else { return false }
            return sentenceEnds.contains(last)
        }), end + 1 < kept.count {
            return kept[(end + 1)...].joined(separator: " ")
        }
        return "…" + kept.joined(separator: " ")
    }
}

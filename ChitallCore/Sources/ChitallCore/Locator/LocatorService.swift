import Foundation

public enum LocatorResolution: Hashable, Sendable {
    /// Paths and offsets point at the same text that was selected.
    case exact(BlockRange)
    /// The source changed; the quote was found elsewhere and the range moved there.
    case relocated(BlockRange)
    /// A caret locator (reading position) resolved to a position.
    case caret(BlockPosition)
    /// The text is no longer in the book. The highlight stays in Materials.
    case notFound

    public var range: BlockRange? {
        switch self {
        case let .exact(range), let .relocated(range): return range
        case .caret, .notFound: return nil
        }
    }
}

/// Creates locators for selections in a book and resolves stored locators back to ranges.
public struct LocatorService: Sendable {
    public let book: ReadableBook
    public let fingerprint: String

    public init(book: ReadableBook, fingerprint: String) {
        self.book = book
        self.fingerprint = fingerprint
    }

    // MARK: Creating

    public func locator(for range: BlockRange) -> Locator? {
        guard range.start < range.end,
              let startBlock = book.block(range.start.block),
              let endBlock = book.block(range.end.block),
              let chapter = book.chapterIndex(ofBlock: range.start.block),
              range.start.offset <= startBlock.length,
              range.end.offset <= endBlock.length else { return nil }
        let exact = book.text(in: range)
        guard !exact.isEmpty else { return nil }
        return Locator(
            format: book.format,
            book: fingerprint,
            chapter: chapter,
            start: point(startBlock, range.start.offset),
            end: point(endBlock, range.end.offset),
            progression: Self.rounded(book.progression(of: range.start)),
            quote: Locator.Quote(
                exact: exact,
                prefix: book.text(before: range.start, limit: Locator.contextLength),
                suffix: book.text(after: range.end, limit: Locator.contextLength)
            )
        )
    }

    /// A caret locator, used for the reading position.
    public func locator(at position: BlockPosition) -> Locator? {
        guard let block = book.block(position.block), let chapter = book.chapterIndex(ofBlock: position.block) else {
            return nil
        }
        return Locator(
            format: book.format,
            book: fingerprint,
            chapter: chapter,
            start: point(block, min(position.offset, block.length)),
            end: nil,
            progression: Self.rounded(book.progression(of: position)),
            quote: nil
        )
    }

    // MARK: Resolving

    public func resolve(_ locator: Locator) -> LocatorResolution {
        resolveAll([locator])[0]
    }

    /// Resolves many locators, building the text search index at most once.
    public func resolveAll(_ locators: [Locator]) -> [LocatorResolution] {
        var index: SearchIndex?
        return locators.map { locator in
            if let resolution = resolveDirectly(locator) { return resolution }
            guard let quote = locator.quote, !quote.exact.isEmpty else {
                return locator.end == nil ? caretByProgression(locator.progression) : .notFound
            }
            if index == nil { index = SearchIndex(book: book) }
            return index!.search(quote, near: locator.progression).map { LocatorResolution.relocated($0) } ?? .notFound
        }
    }

    private func resolveDirectly(_ locator: Locator) -> LocatorResolution? {
        guard let startOrdinal = book.ordinal(of: locator.start.anchor),
              let startBlock = book.block(startOrdinal) else { return nil }

        guard let endPoint = locator.end else {
            let offset = max(0, min(locator.start.offset, startBlock.length))
            return .caret(BlockPosition(block: startOrdinal, offset: offset))
        }
        guard let endOrdinal = book.ordinal(of: endPoint.anchor),
              let endBlock = book.block(endOrdinal),
              locator.start.offset >= 0, locator.start.offset <= startBlock.length,
              endPoint.offset >= 0, endPoint.offset <= endBlock.length else { return nil }
        let range = BlockRange(
            start: BlockPosition(block: startOrdinal, offset: locator.start.offset),
            end: BlockPosition(block: endOrdinal, offset: endPoint.offset)
        )
        guard range.start < range.end else { return nil }
        if let quote = locator.quote, book.text(in: range) != quote.exact { return nil }
        return .exact(range)
    }

    private func caretByProgression(_ progression: Double) -> LocatorResolution {
        book.position(atProgression: progression).map(LocatorResolution.caret) ?? .notFound
    }

    private func point(_ block: Block, _ offset: Int) -> Locator.Point {
        Locator.Point(resource: block.anchor.resource, path: block.anchor.path, offset: offset)
    }

    static func rounded(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }
}

/// Whole-book text as scalars (text blocks joined with "\n") for re-anchoring by quote.
struct SearchIndex {
    private let scalars: [Unicode.Scalar]
    private let starts: [(ordinal: Int, start: Int, length: Int)]
    private let total: Int

    init(book: ReadableBook) {
        var scalars: [Unicode.Scalar] = []
        var starts: [(ordinal: Int, start: Int, length: Int)] = []
        for chapter in book.chapters {
            for block in chapter.blocks where block.hasText {
                if !scalars.isEmpty { scalars.append("\n") }
                starts.append((block.ordinal, scalars.count, block.length))
                scalars.append(contentsOf: block.text.unicodeScalars)
            }
        }
        self.scalars = scalars
        self.starts = starts
        self.total = max(1, scalars.count)
    }

    func search(_ quote: Locator.Quote, near progression: Double) -> BlockRange? {
        let needle = Array(quote.exact.unicodeScalars)
        guard !needle.isEmpty, needle.count <= scalars.count else { return nil }
        let prefix = Array(quote.prefix.unicodeScalars)
        let suffix = Array(quote.suffix.unicodeScalars)

        var best: (start: Int, context: Int, distance: Double)?
        var candidates = 0
        let first = needle[0]
        var index = 0
        let lastStart = scalars.count - needle.count
        while index <= lastStart {
            if scalars[index] == first, matches(needle, at: index) {
                candidates += 1
                let context = commonSuffix(prefix, endingAt: index) + commonPrefix(suffix, startingAt: index + needle.count)
                let distance = abs(Double(index) / Double(total) - progression)
                if best == nil || context > best!.context || (context == best!.context && distance < best!.distance) {
                    best = (index, context, distance)
                }
            }
            index += 1
        }
        guard let best else { return nil }
        // A short quote that occurs several times and matches no context is a guess, not a match.
        if candidates > 1, best.context == 0, needle.count < 12 { return nil }
        guard let start = position(at: best.start), let end = position(at: best.start + needle.count) else { return nil }
        return BlockRange(start: start, end: end)
    }

    private func matches(_ needle: [Unicode.Scalar], at index: Int) -> Bool {
        var offset = 0
        while offset < needle.count {
            if scalars[index + offset] != needle[offset] { return false }
            offset += 1
        }
        return true
    }

    private func commonSuffix(_ prefix: [Unicode.Scalar], endingAt index: Int) -> Int {
        var count = 0
        while count < prefix.count, index - count - 1 >= 0,
              scalars[index - count - 1] == prefix[prefix.count - count - 1] {
            count += 1
        }
        return count
    }

    private func commonPrefix(_ suffix: [Unicode.Scalar], startingAt index: Int) -> Int {
        var count = 0
        while count < suffix.count, index + count < scalars.count, scalars[index + count] == suffix[count] {
            count += 1
        }
        return count
    }

    /// Maps a scalar index of the joined text to a block position.
    private func position(at index: Int) -> BlockPosition? {
        var low = 0
        var high = starts.count - 1
        guard high >= 0 else { return nil }
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle].start <= index { low = middle } else { high = middle - 1 }
        }
        let entry = starts[low]
        guard index >= entry.start, index <= entry.start + entry.length else { return nil }
        return BlockPosition(block: entry.ordinal, offset: index - entry.start)
    }
}

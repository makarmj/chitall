/// Full-text search over the whole book (all chapters, notes included).
///
/// Matching is case-insensitive and treats "ё" as "е". Folding is done scalar by scalar, so
/// offsets in the folded text are offsets in the canonical text and hits map to exact
/// `BlockRange`s. A match never crosses a paragraph boundary; whitespace inside the query is
/// collapsed the same way canonical text collapses it.
public enum BookSearch {
    public struct Hit: Hashable, Sendable, Identifiable {
        public let range: BlockRange
        public let chapterIndex: Int
        /// Context around the match for the result list.
        public let before: String
        public let match: String
        public let after: String

        public var id: BlockRange { range }
    }

    public struct Result: Sendable {
        public let query: String
        public let hits: [Hit]
        /// More matches exist than `limit`.
        public let isTruncated: Bool
    }

    public static let defaultLimit = 300
    public static let contextLength = 40

    public static func search(_ query: String, in book: ReadableBook, limit: Int = defaultLimit) -> Result {
        let needle = fold(TextCanonicalizer.canonicalText(query))
        guard !needle.isEmpty else { return Result(query: query, hits: [], isTruncated: false) }

        var hits: [Hit] = []
        for chapter in book.chapters {
            for block in chapter.blocks where block.length >= needle.count {
                let original = Array(block.text.unicodeScalars)
                let folded = original.map(foldScalar)
                var start = 0
                while start + needle.count <= folded.count {
                    guard let found = firstIndex(of: needle, in: folded, from: start) else { break }
                    if hits.count == limit {
                        return Result(query: query, hits: hits, isTruncated: true)
                    }
                    let end = found + needle.count
                    hits.append(Hit(
                        range: BlockRange(
                            start: BlockPosition(block: block.ordinal, offset: found),
                            end: BlockPosition(block: block.ordinal, offset: end)
                        ),
                        chapterIndex: chapter.index,
                        before: snippet(original, max(0, found - contextLength)..<found, leading: true),
                        match: ReadableBook.string(Array(original[found..<end])),
                        after: snippet(original, end..<min(original.count, end + contextLength), leading: false)
                    ))
                    start = end
                }
            }
        }
        return Result(query: query, hits: hits, isTruncated: false)
    }

    static func fold(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.map(foldScalar)
    }

    /// Lowercases a scalar only when the lowercase form is a single scalar, so lengths never change.
    static func foldScalar(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar {
        case "ё", "Ё": return "е"
        default:
            let lower = scalar.properties.lowercaseMapping.unicodeScalars
            return lower.count == 1 ? lower.first! : scalar
        }
    }

    private static func firstIndex(of needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], from start: Int) -> Int? {
        let first = needle[0]
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first {
                var offset = 1
                while offset < needle.count, haystack[index + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return index }
            }
            index += 1
        }
        return nil
    }

    private static func snippet(_ scalars: [Unicode.Scalar], _ range: Range<Int>, leading: Bool) -> String {
        let text = ReadableBook.string(Array(scalars[range]))
        if leading { return range.lowerBound > 0 ? "…" + text : text }
        return range.upperBound < scalars.count ? text + "…" : text
    }
}

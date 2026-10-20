import Foundation

/// The steps of the "по одному абзацу" reading mode: what one screen shows, in display
/// (UTF-16) offsets of a `ChapterText`. Every step is made of whole blocks, so a highlight,
/// a bookmark or the reading position stays in the same chapter coordinates as in the other
/// modes.
///
/// A step is one paragraph, with a few joins so that a screen still reads as a unit:
/// a heading comes with what follows it, a signature or a date with what it signs, the
/// lines of one stanza and the cells of a table stay together, a run of short lines
/// (dialogue) shares a screen, and so do the paragraphs of one epigraph.
public struct ParagraphSteps: Sendable, Equatable {
    /// Paragraphs shorter than this (lines of dialogue) share a screen.
    public static let shortParagraph = 60
    /// Short paragraphs are joined only while the screen stays this short.
    public static let shortScreen = 200
    /// Verses, table cells and epigraphs are joined up to about this many characters.
    public static let longScreen = 600

    /// UTF-16 ranges in the chapter string, ascending and not overlapping. A range starts at
    /// its first block and ends at the end of its last block (no trailing "\n").
    public let ranges: [Range<Int>]

    public var count: Int { ranges.count }

    public init(_ text: ChapterText) {
        var ranges: [Range<Int>] = []
        var group: Group?
        for segment in text.segments {
            let block = segment.block
            guard block.role == .image || !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let kind = Kind(block)
            if var current = group, current.accepts(kind, length: segment.range.count) {
                current.append(kind, range: segment.range)
                group = current
            } else {
                if let current = group { ranges.append(current.range) }
                group = Group(kind: kind, range: segment.range)
            }
        }
        if let group { ranges.append(group.range) }
        self.ranges = ranges
    }

    /// The step that shows `offset`: the last one starting at or before it (offsets between
    /// steps belong to the step above them, offsets before the first one to the first).
    public func index(containing offset: Int) -> Int {
        guard !ranges.isEmpty else { return 0 }
        var low = 0
        var high = ranges.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if ranges[middle].lowerBound <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    private enum Kind: Equatable {
        case heading
        case signature
        case verse(stanza: String)
        case table
        case epigraph
        case image
        case prose

        init(_ block: Block) {
            switch block.role {
            case .title, .subtitle: self = .heading
            case .textAuthor, .date: self = .signature
            case .verse:
                // "/…/stanza[2]/v[3]" → the stanza "/…/stanza[2]".
                let path = block.anchor.path
                self = .verse(stanza: path.range(of: "/", options: .backwards).map { String(path[..<$0.lowerBound]) } ?? path)
            case .tableCell: self = .table
            case .image: self = .image
            case .paragraph, .emptyLine:
                self = block.context.contains(.epigraph) ? .epigraph : .prose
            }
        }
    }

    private struct Group {
        var start: Int
        var end: Int
        var last: Kind
        var lastLength: Int
        /// Characters of the group after its heading (the heading itself does not count).
        var length: Int

        init(kind: Kind, range: Range<Int>) {
            start = range.lowerBound
            end = range.upperBound
            last = kind
            lastLength = range.count
            length = kind == .heading ? 0 : range.count
        }

        var range: Range<Int> { start..<end }

        func accepts(_ next: Kind, length nextLength: Int) -> Bool {
            if next == .signature { return true }
            if last == .heading { return true }
            if next == .heading { return false }
            switch (last, next) {
            case let (.verse(a), .verse(b)): return a == b && length < ParagraphSteps.longScreen
            case (.table, .table), (.epigraph, .epigraph): return length < ParagraphSteps.longScreen
            case (.prose, .prose):
                return lastLength < ParagraphSteps.shortParagraph
                    && nextLength < ParagraphSteps.shortParagraph
                    && length + nextLength <= ParagraphSteps.shortScreen
            default: return false
            }
        }

        mutating func append(_ kind: Kind, range: Range<Int>) {
            end = range.upperBound
            if kind != .heading { length += range.count }
            // A signature does not change what the screen is: verses stay verses.
            if kind != .signature {
                last = kind
                lastLength = range.count
            }
        }
    }
}

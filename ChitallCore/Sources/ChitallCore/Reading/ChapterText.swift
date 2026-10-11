/// The plain text of one chapter exactly as the reader displays it, plus the map between
/// display offsets (UTF-16, as in NSRange/UITextView) and block positions (Unicode scalars).
///
/// Layout: blocks in order, separated by "\n". A text block contributes its canonical text,
/// an image block one U+FFFC (the app puts an attachment there), a spacing block nothing
/// (an empty line). Rendering only adds attributes, never characters, so the map stays exact.
public struct ChapterText: Sendable {
    public static let attachmentCharacter = "\u{FFFC}"

    public struct Segment: Sendable, Hashable {
        public let block: Block
        /// UTF-16 range of the block's content in `string` (without the trailing "\n").
        public let range: Range<Int>
    }

    public struct Run: Sendable, Hashable {
        /// UTF-16 range in `string`.
        public let range: Range<Int>
        public let inline: InlineRun
    }

    public let chapterIndex: Int
    public let string: String
    public let utf16Length: Int
    public let segments: [Segment]
    public let runs: [Run]

    public init(chapter: Chapter) {
        var string = ""
        var cursor = 0
        var segments: [Segment] = []
        var runs: [Run] = []
        for (index, block) in chapter.blocks.enumerated() {
            if index > 0 {
                string += "\n"
                cursor += 1
            }
            let content: String
            if block.hasText {
                content = block.text
            } else if block.role == .image {
                content = Self.attachmentCharacter
            } else {
                content = ""
            }
            let length = content.utf16.count
            segments.append(Segment(block: block, range: cursor..<(cursor + length)))
            for run in block.runs {
                runs.append(Run(range: (run.range.lowerBound + cursor)..<(run.range.upperBound + cursor), inline: run))
            }
            string += content
            cursor += length
        }
        self.chapterIndex = chapter.index
        self.string = string
        self.utf16Length = cursor
        self.segments = segments
        self.runs = runs
    }

    public var firstBlock: Int? { segments.first?.block.ordinal }
    public var lastBlock: Int? { segments.last?.block.ordinal }

    public func segment(forBlock ordinal: Int) -> Segment? {
        guard let first = firstBlock else { return nil }
        let index = ordinal - first
        guard segments.indices.contains(index), segments[index].block.ordinal == ordinal else { return nil }
        return segments[index]
    }

    /// Display offset of a position in this chapter, or `nil` if the block is elsewhere.
    public func utf16Offset(of position: BlockPosition) -> Int? {
        guard let segment = segment(forBlock: position.block) else { return nil }
        let inBlock = UnicodeOffsets.utf16Offset(in: segment.block.text, scalarOffset: min(position.offset, segment.block.length))
        return segment.range.lowerBound + min(inBlock, segment.range.count)
    }

    /// Block position for a display offset. Offsets on a spacing/image block snap to the
    /// nearest text: forward to the next text block's start, backward to the previous one's end.
    public func position(atUTF16 offset: Int, forward: Bool) -> BlockPosition? {
        guard !segments.isEmpty else { return nil }
        let clamped = max(0, min(offset, utf16Length))
        var low = 0
        var high = segments.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if segments[middle].range.lowerBound <= clamped { low = middle } else { high = middle - 1 }
        }
        let segment = segments[low]
        if segment.block.hasText {
            let inBlock = min(clamped, segment.range.upperBound) - segment.range.lowerBound
            let scalar = UnicodeOffsets.scalarOffset(in: segment.block.text, utf16Offset: inBlock)
            return BlockPosition(block: segment.block.ordinal, offset: scalar)
        }
        if forward {
            guard let next = segments[(low + 1)...].first(where: { $0.block.hasText }) else { return nil }
            return BlockPosition(block: next.block.ordinal, offset: 0)
        } else {
            guard let previous = segments[..<low].last(where: { $0.block.hasText }) else { return nil }
            return BlockPosition(block: previous.block.ordinal, offset: previous.block.length)
        }
    }

    /// Converts a display selection into a block range, moving edges that sit on paragraph
    /// breaks onto the adjacent text. Returns `nil` when the selection contains no text.
    public func blockRange(forUTF16 range: Range<Int>) -> BlockRange? {
        guard var start = position(atUTF16: range.lowerBound, forward: true),
              var end = position(atUTF16: range.upperBound, forward: false) else { return nil }

        if let segment = segment(forBlock: start.block), start.offset >= segment.block.length,
           let next = segments.first(where: { $0.block.ordinal > start.block && $0.block.hasText }) {
            start = BlockPosition(block: next.block.ordinal, offset: 0)
        }
        if end.offset == 0,
           let previous = segments.last(where: { $0.block.ordinal < end.block && $0.block.hasText }) {
            end = BlockPosition(block: previous.block.ordinal, offset: previous.block.length)
        }
        guard start < end else { return nil }
        return BlockRange(start: start, end: end)
    }

    /// Display range of a block range, clipped to this chapter (highlights may span chapters).
    public func utf16Range(of range: BlockRange) -> Range<Int>? {
        guard let first = firstBlock, let last = lastBlock else { return nil }
        guard range.end.block >= first, range.start.block <= last else { return nil }
        let lower = range.start.block < first ? 0 : (utf16Offset(of: range.start) ?? 0)
        let upper = range.end.block > last ? utf16Length : (utf16Offset(of: range.end) ?? utf16Length)
        guard lower < upper else { return nil }
        return lower..<upper
    }
}

import Foundation

/// Source formats. Only FB2 is imported in the MVP; EPUB plugs into the same model later.
public enum BookFormat: String, Codable, Sendable {
    case fb2
    case epub
}

/// Where a block lives in the source document. `resource` is the file inside a container
/// (an EPUB spine item); it is `nil` for single-file formats such as FB2.
public struct TextAnchor: Hashable, Codable, Sendable {
    public var resource: String?
    public var path: String

    public init(resource: String? = nil, path: String) {
        self.resource = resource
        self.path = path
    }
}

/// A position inside the book: block (by global document order) + Unicode scalar offset
/// in that block's canonical text.
public struct BlockPosition: Hashable, Comparable, Codable, Sendable {
    public var block: Int
    public var offset: Int

    public init(block: Int, offset: Int) {
        self.block = block
        self.offset = offset
    }

    public static func < (lhs: BlockPosition, rhs: BlockPosition) -> Bool {
        lhs.block != rhs.block ? lhs.block < rhs.block : lhs.offset < rhs.offset
    }
}

/// A half-open range of text, `start ..< end`.
public struct BlockRange: Hashable, Codable, Sendable {
    public var start: BlockPosition
    public var end: BlockPosition

    public init(start: BlockPosition, end: BlockPosition) {
        self.start = start
        self.end = end
    }
}

public struct Person: Hashable, Codable, Sendable {
    public var firstName: String
    public var middleName: String
    public var lastName: String
    public var nickname: String

    public init(firstName: String = "", middleName: String = "", lastName: String = "", nickname: String = "") {
        self.firstName = firstName
        self.middleName = middleName
        self.lastName = lastName
        self.nickname = nickname
    }

    public var displayName: String {
        let full = [firstName, middleName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return full.isEmpty ? nickname : full
    }
}

public struct BookSeries: Hashable, Codable, Sendable {
    public var name: String
    public var number: String?
}

public struct BookMetadata: Hashable, Codable, Sendable {
    public var title: String = ""
    public var authors: [Person] = []
    public var translators: [Person] = []
    public var genres: [String] = []
    public var keywords: [String] = []
    public var language: String?
    public var sourceLanguage: String?
    public var annotation: String?
    public var date: String?
    public var series: BookSeries?
    public var documentID: String?
    public var documentVersion: String?
    public var publisher: String?
    public var publishYear: String?
    public var isbn: String?
    public var coverImageID: String?

    public init() {}

    public var authorLine: String {
        authors.map(\.displayName).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// What a block is. Rendering decides typography from role + context.
public enum BlockRole: String, Codable, Sendable {
    case paragraph
    case title
    case subtitle
    case verse
    case textAuthor
    case date
    case tableCell
    case emptyLine
    case image
}

public struct BlockContext: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let epigraph = BlockContext(rawValue: 1 << 0)
    public static let cite = BlockContext(rawValue: 1 << 1)
    public static let poem = BlockContext(rawValue: 1 << 2)
    public static let annotation = BlockContext(rawValue: 1 << 3)
    public static let notes = BlockContext(rawValue: 1 << 4)
    public static let table = BlockContext(rawValue: 1 << 5)
}

public struct InlineStyle: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let emphasis = InlineStyle(rawValue: 1 << 0)
    public static let strong = InlineStyle(rawValue: 1 << 1)
    public static let strikethrough = InlineStyle(rawValue: 1 << 2)
    public static let subscript_ = InlineStyle(rawValue: 1 << 3)
    public static let superscript = InlineStyle(rawValue: 1 << 4)
    public static let code = InlineStyle(rawValue: 1 << 5)
}

/// Styled stretch of a block's canonical text. `range` is in UTF-16 units of `Block.text`.
public struct InlineRun: Hashable, Codable, Sendable {
    public var range: Range<Int>
    public var style: InlineStyle
    /// Target of a hyperlink, without the leading `#` for internal links.
    public var link: String?
    public var isNoteReference: Bool

    public init(range: Range<Int>, style: InlineStyle, link: String? = nil, isNoteReference: Bool = false) {
        self.range = range
        self.style = style
        self.link = link
        self.isNoteReference = isNoteReference
    }
}

public struct Block: Hashable, Sendable {
    /// Global index in document order across all chapters.
    public let ordinal: Int
    public let anchor: TextAnchor
    public let role: BlockRole
    public let context: BlockContext
    /// 0 for the book/body title, 1 for top-level sections, deeper for nested ones.
    public let titleLevel: Int
    /// Canonical text (see docs/locator.md). Empty for spacing and image blocks.
    public let text: String
    public let runs: [InlineRun]
    public let elementID: String?
    public let imageID: String?
    /// Number of Unicode scalars in `text`.
    public let length: Int

    public init(
        ordinal: Int,
        anchor: TextAnchor,
        role: BlockRole,
        context: BlockContext,
        titleLevel: Int = 0,
        text: String,
        runs: [InlineRun] = [],
        elementID: String? = nil,
        imageID: String? = nil
    ) {
        self.ordinal = ordinal
        self.anchor = anchor
        self.role = role
        self.context = context
        self.titleLevel = titleLevel
        self.text = text
        self.runs = runs
        self.elementID = elementID
        self.imageID = imageID
        self.length = text.unicodeScalars.count
    }

    public var hasText: Bool { length > 0 }
}

public struct TOCEntry: Hashable, Sendable, Identifiable {
    public var id: Int { firstBlock }
    public let title: String
    public let depth: Int
    public let firstBlock: Int
}

public struct Chapter: Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let title: String
    public let anchor: TextAnchor
    public let blocks: [Block]
    public let tableOfContents: [TOCEntry]
    public let isNotes: Bool

    public var firstBlock: Int { blocks.first?.ordinal ?? 0 }
    public var textLength: Int { blocks.reduce(0) { $0 + $1.length } }
}

public struct NoteContent: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let text: String
    public let chapterIndex: Int
    public let firstBlock: Int
}

public struct BookImage: Hashable, Sendable {
    public let id: String
    public let contentType: String
    public let data: Data
}

/// The format-agnostic book every screen works with. FB2 today, EPUB tomorrow: an importer
/// produces this value and nothing downstream knows which format it came from.
public struct ReadableBook: Sendable {
    public let format: BookFormat
    public let metadata: BookMetadata
    public let chapters: [Chapter]
    public let notes: [String: NoteContent]
    public let images: [String: BookImage]
    /// Element ids (`id="…"`) → first block ordinal, for internal links.
    public let idTargets: [String: Int]

    private let blockLocations: [Int: (chapter: Int, index: Int)]
    private let ordinalsByAnchor: [TextAnchor: Int]
    /// Scalar offset of each block's start in the whole book text (blocks joined with "\n").
    private let textStarts: [Int: Int]
    public let totalTextLength: Int

    public init(
        format: BookFormat,
        metadata: BookMetadata,
        chapters: [Chapter],
        notes: [String: NoteContent] = [:],
        images: [String: BookImage] = [:],
        idTargets: [String: Int] = [:]
    ) {
        self.format = format
        self.metadata = metadata
        self.chapters = chapters
        self.notes = notes
        self.images = images
        self.idTargets = idTargets

        var locations: [Int: (chapter: Int, index: Int)] = [:]
        var anchors: [TextAnchor: Int] = [:]
        var starts: [Int: Int] = [:]
        var cursor = 0
        var first = true
        for chapter in chapters {
            for (index, block) in chapter.blocks.enumerated() {
                locations[block.ordinal] = (chapter.index, index)
                anchors[block.anchor] = block.ordinal
                guard block.hasText else { continue }
                if !first { cursor += 1 }
                first = false
                starts[block.ordinal] = cursor
                cursor += block.length
            }
        }
        self.blockLocations = locations
        self.ordinalsByAnchor = anchors
        self.textStarts = starts
        self.totalTextLength = cursor
    }

    public var blockCount: Int { blockLocations.count }

    public func block(_ ordinal: Int) -> Block? {
        guard let location = blockLocations[ordinal] else { return nil }
        return chapters[location.chapter].blocks[location.index]
    }

    public func chapterIndex(ofBlock ordinal: Int) -> Int? {
        blockLocations[ordinal]?.chapter
    }

    public func ordinal(of anchor: TextAnchor) -> Int? {
        ordinalsByAnchor[anchor]
    }

    /// Position in the whole book, 0…1.
    public func progression(of position: BlockPosition) -> Double {
        guard totalTextLength > 0 else { return 0 }
        if let start = textStarts[position.block] {
            return min(1, Double(start + position.offset) / Double(totalTextLength))
        }
        // A non-text block: use the next text block after it.
        var ordinal = position.block
        while blockLocations[ordinal] != nil {
            if let start = textStarts[ordinal] { return Double(start) / Double(totalTextLength) }
            ordinal += 1
        }
        return 1
    }

    /// The position at a 0…1 share of the whole book text (the inverse of `progression(of:)`),
    /// used by the progress slider and as a fallback for a lost reading position.
    public func position(atProgression progression: Double) -> BlockPosition? {
        guard totalTextLength > 0 else {
            return chapters.first?.blocks.first.map { BlockPosition(block: $0.ordinal, offset: 0) }
        }
        // Nearest, not floor: progression × length lands a hair below a block start in floating point.
        let target = Int((max(0, min(1, progression)) * Double(totalTextLength)).rounded())
        var last: Block?
        for chapter in chapters {
            for block in chapter.blocks where block.hasText {
                guard let start = textStarts[block.ordinal] else { continue }
                if target <= start + block.length {
                    return BlockPosition(block: block.ordinal, offset: max(0, target - start))
                }
                last = block
            }
        }
        return last.map { BlockPosition(block: $0.ordinal, offset: $0.length) }
    }

    /// Text between two positions; blocks are joined with "\n". Non-text blocks contribute nothing.
    public func text(in range: BlockRange) -> String {
        guard range.start < range.end else { return "" }
        var parts: [String] = []
        var ordinal = range.start.block
        while ordinal <= range.end.block, let block = block(ordinal) {
            if block.hasText {
                let lower = ordinal == range.start.block ? range.start.offset : 0
                let upper = ordinal == range.end.block ? range.end.offset : block.length
                parts.append(UnicodeOffsets.substring(block.text, scalarRange: lower..<max(lower, upper)))
            }
            ordinal += 1
        }
        return parts.joined(separator: "\n")
    }

    /// Up to `limit` scalars of book text right before `position`, blocks joined with "\n".
    public func text(before position: BlockPosition, limit: Int) -> String {
        var pieces: [[Unicode.Scalar]] = []
        var remaining = limit
        var ordinal = position.block
        while remaining > 0, ordinal >= 0, let block = block(ordinal) {
            if block.hasText {
                var scalars: [Unicode.Scalar]
                if ordinal == position.block {
                    scalars = Array(block.text.unicodeScalars.prefix(max(0, position.offset)))
                } else {
                    scalars = Array(block.text.unicodeScalars)
                    scalars.append("\n")
                }
                let taken = Array(scalars.suffix(remaining))
                pieces.append(taken)
                remaining -= taken.count
            }
            ordinal -= 1
        }
        return Self.string(pieces.reversed().flatMap { $0 })
    }

    /// Up to `limit` scalars of book text right after `position`, blocks joined with "\n".
    public func text(after position: BlockPosition, limit: Int) -> String {
        var result: [Unicode.Scalar] = []
        var ordinal = position.block
        while result.count < limit, let block = block(ordinal) {
            if block.hasText {
                if ordinal == position.block {
                    result.append(contentsOf: block.text.unicodeScalars.dropFirst(max(0, position.offset)))
                } else {
                    result.append("\n")
                    result.append(contentsOf: block.text.unicodeScalars)
                }
            }
            ordinal += 1
        }
        return Self.string(Array(result.prefix(limit)))
    }

    static func string(_ scalars: [Unicode.Scalar]) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}

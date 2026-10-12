import Foundation

/// One highlight as research material, with full provenance. It is self-contained: export
/// works even after the book itself was deleted from the library.
public struct MaterialItem: Hashable, Sendable {
    public var id: String
    public var bookFingerprint: String
    public var bookTitle: String
    public var bookAuthors: String
    public var chapterIndex: Int
    public var chapterTitle: String
    public var text: String
    public var note: String
    public var tags: [String]
    public var color: HighlightColor
    public var createdAt: Date
    public var updatedAt: Date
    public var locator: Locator

    public init(
        id: String,
        bookFingerprint: String,
        bookTitle: String,
        bookAuthors: String,
        chapterIndex: Int,
        chapterTitle: String,
        text: String,
        note: String,
        tags: [String],
        color: HighlightColor,
        createdAt: Date,
        updatedAt: Date,
        locator: Locator
    ) {
        self.id = id
        self.bookFingerprint = bookFingerprint
        self.bookTitle = bookTitle
        self.bookAuthors = bookAuthors
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.text = text
        self.note = note
        self.tags = tags
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.locator = locator
    }
}

/// What the user chose to export, ready to be rendered as Markdown and JSON.
public struct MaterialExport: Sendable {
    public var items: [MaterialItem]
    public var exportedAt: Date
    /// Human description of the selection, e.g. "все материалы" or "тег #тайна".
    public var selectionDescription: String
    public var generator: String
    public var timeZone: TimeZone

    public init(
        items: [MaterialItem],
        exportedAt: Date,
        selectionDescription: String,
        generator: String = "Chitall",
        timeZone: TimeZone = .current
    ) {
        self.items = items
        self.exportedAt = exportedAt
        self.selectionDescription = selectionDescription
        self.generator = generator
        self.timeZone = timeZone
    }

    public struct BookGroup: Sendable {
        public let fingerprint: String
        public let title: String
        public let authors: String
        public let items: [MaterialItem]
    }

    /// Books ordered by title, highlights in reading order inside each book.
    public var groupedByBook: [BookGroup] {
        let groups = Dictionary(grouping: items, by: \.bookFingerprint)
        return groups.map { fingerprint, items -> BookGroup in
            let sorted = items.sorted { lhs, rhs in
                if lhs.locator.progression != rhs.locator.progression {
                    return lhs.locator.progression < rhs.locator.progression
                }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
            let representative = items.max { $0.updatedAt < $1.updatedAt } ?? items[0]
            return BookGroup(
                fingerprint: fingerprint,
                title: representative.bookTitle,
                authors: representative.bookAuthors,
                items: sorted
            )
        }
        .sorted { lhs, rhs in
            let left = lhs.title.lowercased()
            let right = rhs.title.lowercased()
            return left != right ? left < right : lhs.fingerprint < rhs.fingerprint
        }
    }

    /// File name stem such as `chitall-materials-20261011-1530`.
    public var fileStem: String {
        let c = Self.components(exportedAt, timeZone)
        return "chitall-materials-" + Self.pad(c.year, 4) + Self.pad(c.month, 2) + Self.pad(c.day, 2)
            + "-" + Self.pad(c.hour, 2) + Self.pad(c.minute, 2)
    }

    // MARK: Formatting helpers (locale-independent on purpose: exports must be reproducible)

    static func components(_ date: Date, _ timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    static func pad(_ value: Int?, _ width: Int) -> String {
        let text = String(value ?? 0)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    static func dateTime(_ date: Date, _ timeZone: TimeZone) -> String {
        let c = components(date, timeZone)
        return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2)) \(pad(c.hour, 2)):\(pad(c.minute, 2))"
    }

    /// 0.12345 → "12,3 %".
    public static func percent(_ progression: Double) -> String {
        let permille = Int((max(0, min(1, progression)) * 1000).rounded())
        return "\(permille / 10),\(permille % 10) %"
    }

    /// Reading progress in the reader: whole percent, rounded down, so "100 %" appears only
    /// at the very end of the book (`atEnd`), never a page before it. 0.365 → "36 %".
    public static func wholePercent(_ progression: Double, atEnd: Bool = false) -> String {
        if atEnd || progression >= 1 { return "100 %" }
        let percent = Int((max(0, progression) * 100 + 1e-9).rounded(.down))
        return "\(min(99, percent)) %"
    }
}

import Foundation

/// A stable, exact pointer into a book's source: `chitall.locator` version 1.
/// Specification: docs/locator.md.
public struct Locator: Hashable, Codable, Sendable {
    public static let currentVersion = 1
    public static let contextLength = 32

    public struct Point: Hashable, Codable, Sendable {
        /// File inside a container format (EPUB); omitted for FB2.
        public var resource: String?
        /// XPath-like path over local element names, e.g. `/FictionBook/body[1]/section[4]/p[12]`.
        public var path: String
        /// Unicode scalar offset in the element's canonical text.
        public var offset: Int

        public init(resource: String? = nil, path: String, offset: Int) {
            self.resource = resource
            self.path = path
            self.offset = offset
        }

        public var anchor: TextAnchor { TextAnchor(resource: resource, path: path) }
    }

    /// Text quote selector: the selected text and up to 32 scalars of context on each side.
    public struct Quote: Hashable, Codable, Sendable {
        public var exact: String
        public var prefix: String
        public var suffix: String

        public init(exact: String, prefix: String, suffix: String) {
            self.exact = exact
            self.prefix = prefix
            self.suffix = suffix
        }
    }

    public var v: Int
    public var format: BookFormat
    /// `sha256:<hex>` of the source file.
    public var book: String
    /// Chapter index at creation time. Informational; resolution relies on paths and quote.
    public var chapter: Int
    public var start: Point
    /// End of a range (exclusive). `nil` for a caret position such as the reading position.
    public var end: Point?
    /// 0…1 position of `start` in the whole book text.
    public var progression: Double
    public var quote: Quote?

    public init(
        format: BookFormat,
        book: String,
        chapter: Int,
        start: Point,
        end: Point?,
        progression: Double,
        quote: Quote?
    ) {
        self.v = Self.currentVersion
        self.format = format
        self.book = book
        self.chapter = chapter
        self.start = start
        self.end = end
        self.progression = progression
        self.quote = quote
    }

    /// The form that leaves the device in exports: no quote context, which is book text the
    /// user did not select (the exact text is exported separately as the highlight's text).
    public var withoutQuote: Locator {
        var copy = self
        copy.quote = nil
        return copy
    }

    /// Compact single-line form for Markdown, e.g. `p[12]:15–p[13]:40`.
    public var compactDescription: String {
        let startText = "\(start.path):\(start.offset)"
        guard let end else { return startText }
        if end.path == start.path { return "\(startText)–\(end.offset)" }
        return "\(startText)–\(end.path):\(end.offset)"
    }

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func fromJSONString(_ string: String) throws -> Locator {
        let locator = try JSONDecoder().decode(Locator.self, from: Data(string.utf8))
        guard locator.v <= currentVersion else { throw LocatorError.unsupportedVersion(locator.v) }
        return locator
    }
}

public enum LocatorError: Error, Equatable {
    case unsupportedVersion(Int)
}

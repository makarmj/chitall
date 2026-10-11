import Foundation

/// Search and filters of the Materials screen. Pure logic so it is tested with the core.
///
/// Search words must all occur in the quote, the thought, the tags, the book or chapter title
/// (case-insensitive, "ё" = "е"). A word starting with `#` matches a tag exactly, so typing
/// `#тайна` filters by that tag.
public struct MaterialFilter: Equatable, Sendable {
    public var query: String
    public var bookFingerprint: String?
    public var tag: String?
    public var color: HighlightColor?

    public init(query: String = "", bookFingerprint: String? = nil, tag: String? = nil, color: HighlightColor? = nil) {
        self.query = query
        self.bookFingerprint = bookFingerprint
        self.tag = tag
        self.color = color
    }

    public var isActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || bookFingerprint != nil || tag != nil || color != nil
    }

    public func matches(
        text: String,
        note: String,
        tags: [String],
        color: HighlightColor,
        bookFingerprint: String,
        bookTitle: String,
        chapterTitle: String
    ) -> Bool {
        if let wanted = self.bookFingerprint, wanted != bookFingerprint { return false }
        if let wanted = self.tag, !tags.contains(wanted) { return false }
        if let wanted = self.color, wanted != color { return false }

        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = Self.fold([text, note, bookTitle, chapterTitle, tags.joined(separator: " ")].joined(separator: "\n"))
        for word in words {
            if word.hasPrefix("#") {
                guard let tagName = TagNames.normalize(word) else { continue }
                if !tags.contains(tagName) { return false }
            } else if !haystack.contains(Self.fold(word)) {
                return false
            }
        }
        return true
    }

    public func matches(_ item: MaterialItem) -> Bool {
        matches(
            text: item.text,
            note: item.note,
            tags: item.tags,
            color: item.color,
            bookFingerprint: item.bookFingerprint,
            bookTitle: item.bookTitle,
            chapterTitle: item.chapterTitle
        )
    }

    /// Human description used in exports, e.g. "книга «Соляной обоз», тег #тайна".
    public func summary(bookTitle: String?) -> String {
        var parts: [String] = []
        if bookFingerprint != nil { parts.append("книга «\(bookTitle ?? "без названия")»") }
        if let tag { parts.append("тег \(TagNames.display(tag))") }
        if let color { parts.append("цвет \(color.displayName)") }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append("поиск «\(trimmed)»") }
        return parts.isEmpty ? "все материалы" : parts.joined(separator: ", ")
    }

    public static func fold(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}

/// Russian plural forms: 1 выделение, 2 выделения, 5 выделений.
public enum RussianPlural {
    public static func form(_ count: Int, one: String, few: String, many: String) -> String {
        let lastTwo = abs(count) % 100
        let last = abs(count) % 10
        if last == 1, lastTwo != 11 { return one }
        if (2...4).contains(last), !(12...14).contains(lastTwo) { return few }
        return many
    }

    public static func highlights(_ count: Int) -> String {
        "\(count) " + form(count, one: "выделение", few: "выделения", many: "выделений")
    }

    public static func books(_ count: Int) -> String {
        "\(count) " + form(count, one: "книга", few: "книги", many: "книг")
    }
}

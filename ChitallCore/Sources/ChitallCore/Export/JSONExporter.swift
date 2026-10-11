import Foundation

/// Machine-readable export, schema `chitall.export` version 1 (docs/export-format.md).
public enum JSONExporter {
    public static let schema = "chitall.export"
    public static let version = 1

    public static func render(_ export: MaterialExport) throws -> Data {
        let groups = export.groupedByBook
        let document = Document(
            schema: schema,
            version: version,
            generator: export.generator,
            exportedAt: export.exportedAt,
            selection: .init(
                description: export.selectionDescription,
                highlightCount: export.items.count,
                bookCount: groups.count
            ),
            books: groups.map { .init(id: $0.fingerprint, title: $0.title, authors: $0.authors) },
            highlights: groups.flatMap(\.items).map { item in
                Highlight(
                    id: item.id,
                    book: item.bookFingerprint,
                    chapter: .init(index: item.chapterIndex, title: item.chapterTitle),
                    text: item.text,
                    note: item.note,
                    tags: item.tags,
                    color: .init(key: item.color.rawValue, name: item.color.displayName),
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    locator: item.locator.withoutQuote
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }

    struct Document: Encodable {
        let schema: String
        let version: Int
        let generator: String
        let exportedAt: Date
        let selection: Selection
        let books: [Book]
        let highlights: [Highlight]
    }

    struct Selection: Encodable {
        let description: String
        let highlightCount: Int
        let bookCount: Int
    }

    struct Book: Encodable {
        let id: String
        let title: String
        let authors: String
    }

    struct Chapter: Encodable {
        let index: Int
        let title: String
    }

    struct Color: Encodable {
        let key: String
        let name: String
    }

    struct Highlight: Encodable {
        let id: String
        let book: String
        let chapter: Chapter
        let text: String
        let note: String
        let tags: [String]
        let color: Color
        let createdAt: Date
        let updatedAt: Date
        let locator: Locator
    }
}

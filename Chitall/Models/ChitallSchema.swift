import Foundation
import SwiftData

// Version 1 of the store, frozen: never edit these models — add a new version instead
// (ChitallSchemaV2.swift). Deliberately flat schema: no relationships between models. SwiftData on iOS 17 has known
// problems with relationship inverses and predicates over to-many relations (DECISIONS.md §5).
// A highlight refers to its book by the file fingerprint and keeps its own provenance copy,
// so it survives deletion of the book and re-attaches when the same file is imported again.
enum ChitallSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [StoredBook.self, Highlight.self, TagRecord.self]
    }

    @Model
    final class StoredBook {
        /// `sha256:<hex>` of the stored `.fb2` bytes.
        @Attribute(.unique) var fingerprint: String
        var title: String
        var authors: String
        var language: String? = nil
        var annotation: String? = nil
        var seriesName: String? = nil
        var seriesNumber: String? = nil
        /// File name inside Application Support/Chitall/Books.
        var fileName: String
        var originalFileName: String
        var fileSize: Int
        var coverFileName: String? = nil
        var chapterCount: Int
        var importedAt: Date
        var lastOpenedAt: Date? = nil
        /// Caret locator (JSON) of the first visible line.
        var readingPositionJSON: String? = nil
        var readingProgress: Double = 0

        init(
            fingerprint: String,
            title: String,
            authors: String,
            fileName: String,
            originalFileName: String,
            fileSize: Int,
            chapterCount: Int,
            importedAt: Date = .now
        ) {
            self.fingerprint = fingerprint
            self.title = title
            self.authors = authors
            self.fileName = fileName
            self.originalFileName = originalFileName
            self.fileSize = fileSize
            self.chapterCount = chapterCount
            self.importedAt = importedAt
        }
    }

    @Model
    final class Highlight {
        @Attribute(.unique) var id: UUID
        var bookFingerprint: String
        var bookTitle: String
        var bookAuthors: String
        var chapterIndex: Int
        var chapterTitle: String
        /// Exactly the selected text, paragraphs joined with "\n".
        var text: String
        var note: String = ""
        /// Normalized tag names (see `TagNames`).
        var tags: [String] = []
        var colorKey: String
        /// `chitall.locator` v1 as JSON (docs/locator.md).
        var locatorJSON: String
        /// Denormalized from the locator for sorting in reading order.
        var progression: Double
        var createdAt: Date
        var updatedAt: Date

        init(
            id: UUID = UUID(),
            bookFingerprint: String,
            bookTitle: String,
            bookAuthors: String,
            chapterIndex: Int,
            chapterTitle: String,
            text: String,
            colorKey: String,
            locatorJSON: String,
            progression: Double,
            createdAt: Date = .now
        ) {
            self.id = id
            self.bookFingerprint = bookFingerprint
            self.bookTitle = bookTitle
            self.bookAuthors = bookAuthors
            self.chapterIndex = chapterIndex
            self.chapterTitle = chapterTitle
            self.text = text
            self.colorKey = colorKey
            self.locatorJSON = locatorJSON
            self.progression = progression
            self.createdAt = createdAt
            self.updatedAt = createdAt
        }
    }

    @Model
    final class TagRecord {
        @Attribute(.unique) var name: String
        var isBuiltIn: Bool
        var sortOrder: Int
        var createdAt: Date

        init(name: String, isBuiltIn: Bool, sortOrder: Int, createdAt: Date = .now) {
            self.name = name
            self.isBuiltIn = isBuiltIn
            self.sortOrder = sortOrder
            self.createdAt = createdAt
        }
    }
}

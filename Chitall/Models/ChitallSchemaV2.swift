import Foundation
import SwiftData

/// Version 2 of the store: adds bookmarks. The other models are unchanged copies of V1; the
/// migration from V1 is lightweight (a new entity only), so existing books and highlights stay.
enum ChitallSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [StoredBook.self, Highlight.self, TagRecord.self, Bookmark.self]
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

    @Model
    final class Bookmark {
        @Attribute(.unique) var id: UUID
        var bookFingerprint: String
        var chapterIndex: Int
        var chapterTitle: String
        /// The first words on the bookmarked page, for the list.
        var snippet: String
        /// Caret locator (JSON) of the first character on the page.
        var locatorJSON: String
        var progression: Double
        var createdAt: Date

        init(
            id: UUID = UUID(),
            bookFingerprint: String,
            chapterIndex: Int,
            chapterTitle: String,
            snippet: String,
            locatorJSON: String,
            progression: Double,
            createdAt: Date = .now
        ) {
            self.id = id
            self.bookFingerprint = bookFingerprint
            self.chapterIndex = chapterIndex
            self.chapterTitle = chapterTitle
            self.snippet = snippet
            self.locatorJSON = locatorJSON
            self.progression = progression
            self.createdAt = createdAt
        }
    }
}

enum ChitallMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [ChitallSchemaV1.self, ChitallSchemaV2.self] }

    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: ChitallSchemaV1.self, toVersion: ChitallSchemaV2.self)]
    }
}

typealias StoredBook = ChitallSchemaV2.StoredBook
typealias Highlight = ChitallSchemaV2.Highlight
typealias TagRecord = ChitallSchemaV2.TagRecord
typealias Bookmark = ChitallSchemaV2.Bookmark

enum ChitallStore {
    static let currentSchema = Schema(versionedSchema: ChitallSchemaV2.self)

    /// On-device store only: CloudKit is explicitly off (no accounts, no sync in the MVP).
    static func makeContainer(inMemory: Bool = false, storeURL: URL? = nil) throws -> ModelContainer {
        let schema = currentSchema
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else if let storeURL {
            configuration = ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration("Chitall", schema: schema, cloudKitDatabase: .none)
        }
        return try ModelContainer(for: schema, migrationPlan: ChitallMigrationPlan.self, configurations: configuration)
    }
}

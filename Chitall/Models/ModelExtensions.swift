import Foundation
import SwiftData

extension Highlight {
    var color: HighlightColor {
        get { HighlightColor(storedValue: colorKey) }
        set { colorKey = newValue.rawValue }
    }

    var locator: Locator? {
        try? Locator.fromJSONString(locatorJSON)
    }

    func touch() {
        updatedAt = .now
    }

    func toggleTag(_ name: String) {
        if let index = tags.firstIndex(of: name) {
            tags.remove(at: index)
        } else {
            tags.append(name)
        }
        touch()
    }

    func matches(_ filter: MaterialFilter) -> Bool {
        filter.matches(
            text: text,
            note: note,
            tags: tags,
            color: color,
            bookFingerprint: bookFingerprint,
            bookTitle: bookTitle,
            chapterTitle: chapterTitle
        )
    }

    /// Export form. `nil` only if the stored locator is unreadable (never written by this version).
    func materialItem() -> MaterialItem? {
        guard let locator else { return nil }
        return MaterialItem(
            id: id.uuidString,
            bookFingerprint: bookFingerprint,
            bookTitle: bookTitle,
            bookAuthors: bookAuthors,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            text: text,
            note: note,
            tags: tags,
            color: color,
            createdAt: createdAt,
            updatedAt: updatedAt,
            locator: locator
        )
    }
}

extension StoredBook {
    /// Last time the book was opened, or import time for books never opened.
    var recencyDate: Date { lastOpenedAt ?? importedAt }

    var readingPosition: Locator? {
        readingPositionJSON.flatMap { try? Locator.fromJSONString($0) }
    }

    /// The stored file's extension is the format (`.epub` or `.fb2`); no schema change needed.
    var format: BookFormat {
        fileName.lowercased().hasSuffix(".epub") ? .epub : .fb2
    }

    /// "EPUB", "FB2" or "FB2 из архива ZIP" for «О книге».
    var formatName: String {
        switch format {
        case .epub: return "EPUB"
        case .fb2: return originalFileName.lowercased().hasSuffix(".zip") ? "FB2 из архива ZIP" : "FB2"
        }
    }
}

@MainActor
enum TagCatalog {
    private static let seededKey = "tags.seeded.v1"

    /// Adds the default tags once. If the user later deletes some, they stay deleted.
    static func seedIfNeeded(_ context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: seededKey) else { return }
        let existing = Set(((try? context.fetch(FetchDescriptor<TagRecord>())) ?? []).map(\.name))
        for (index, name) in TagNames.defaults.enumerated() where !existing.contains(name) {
            context.insert(TagRecord(name: name, isBuiltIn: true, sortOrder: index))
        }
        try? context.save()
        defaults.set(true, forKey: seededKey)
    }

    /// Makes sure a user-typed tag exists in the catalog.
    static func ensure(_ name: String, in context: ModelContext) {
        var descriptor = FetchDescriptor<TagRecord>(predicate: #Predicate<TagRecord> { $0.name == name })
        descriptor.fetchLimit = 1
        if let found = try? context.fetch(descriptor), !found.isEmpty { return }
        let count = (try? context.fetchCount(FetchDescriptor<TagRecord>())) ?? 0
        context.insert(TagRecord(name: name, isBuiltIn: false, sortOrder: 100 + count))
    }
}

import Foundation
import SwiftData

@MainActor
enum LibraryActions {
    static func highlightCount(for fingerprint: String, in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.bookFingerprint == fingerprint })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    /// Removes the book and its files. Highlights either stay as self-contained materials
    /// (they keep title, author, chapter and quote) or are deleted together with the book.
    static func delete(_ book: StoredBook, keepMaterials: Bool, context: ModelContext, files: BookFileStore) throws {
        let fingerprint = book.fingerprint
        if !keepMaterials {
            let descriptor = FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.bookFingerprint == fingerprint })
            for highlight in try context.fetch(descriptor) {
                context.delete(highlight)
            }
        }
        let bookFile = book.fileName
        let coverFile = book.coverFileName
        context.delete(book)
        try context.save()
        files.removeFiles(bookFileName: bookFile, coverFileName: coverFile)
    }
}

/// Writes the export into a fresh temporary folder for the Share Sheet.
enum MaterialExportWriter {
    struct Files {
        let markdown: URL
        let json: URL
        let markdownText: String
    }

    static func write(_ export: MaterialExport) throws -> Files {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let markdownText = MarkdownExporter.render(export)
        let markdownURL = directory.appendingPathComponent(export.fileStem + ".md")
        try Data(markdownText.utf8).write(to: markdownURL, options: .atomic)

        let jsonURL = directory.appendingPathComponent(export.fileStem + ".json")
        try JSONExporter.render(export).write(to: jsonURL, options: .atomic)

        return Files(markdown: markdownURL, json: jsonURL, markdownText: markdownText)
    }

    static var generator: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Chitall \(version) (\(build))"
    }
}

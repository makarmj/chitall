import Foundation
import SwiftData
import UniformTypeIdentifiers

enum BookFileTypes {
    /// FB2 has no system type. The app declares `com.fbreader.book.fb2` as an imported type
    /// (Config/Info.plist); asking by extension picks whatever the system actually resolved.
    static let fb2: UTType = UTType(filenameExtension: "fb2") ?? UTType(importedAs: "com.fbreader.book.fb2")

    static var importable: [UTType] { [fb2, .zip, .xml] }
}

@MainActor
final class BookImportService {
    enum Outcome {
        case imported(StoredBook)
        case alreadyInLibrary(StoredBook)
    }

    private let files: BookFileStore

    init(files: BookFileStore) {
        self.files = files
    }

    func importFile(at url: URL, into context: ModelContext) async throws -> Outcome {
        let data = try await Task.detached(priority: .userInitiated) {
            try Self.readFile(at: url)
        }.value
        return try await importData(data, originalFileName: url.lastPathComponent, into: context)
    }

    func importData(_ data: Data, originalFileName: String, into context: ModelContext) async throws -> Outcome {
        // Parsing a large book takes noticeable time; keep it off the main thread.
        let imported = try await Task.detached(priority: .userInitiated) {
            try BookImporter.importBook(data: data)
        }.value

        let fingerprint = imported.fingerprint
        var descriptor = FetchDescriptor<StoredBook>(predicate: #Predicate<StoredBook> { $0.fingerprint == fingerprint })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            if !files.bookExists(named: existing.fileName) {
                _ = try files.writeBook(imported.sourceData, fingerprint: fingerprint)
            }
            return .alreadyInLibrary(existing)
        }

        let metadata = imported.book.metadata
        let fileName = try files.writeBook(imported.sourceData, fingerprint: fingerprint)
        let book = StoredBook(
            fingerprint: fingerprint,
            title: metadata.title.isEmpty ? Self.title(fromFileName: originalFileName) : metadata.title,
            authors: metadata.authorLine,
            fileName: fileName,
            originalFileName: originalFileName,
            fileSize: imported.sourceData.count,
            chapterCount: imported.book.chapters.count
        )
        book.language = metadata.language
        book.annotation = metadata.annotation
        book.seriesName = metadata.series?.name
        book.seriesNumber = metadata.series?.number
        if let coverID = metadata.coverImageID, let cover = imported.book.images[coverID] {
            book.coverFileName = files.writeCover(cover, fingerprint: fingerprint)
        }
        context.insert(book)
        try context.save()
        return .imported(book)
    }

    /// Reads a file from the Files picker or from "Open in": security-scoped access plus file
    /// coordination, which also downloads iCloud Drive files that are not on the device yet.
    nonisolated static func readFile(at url: URL) throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > BookImporter.maximumFileSize {
            throw BookImportError.fileTooLarge(bytes: size, limit: BookImporter.maximumFileSize)
        }

        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result { try Data(contentsOf: readableURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    static func title(fromFileName name: String) -> String {
        var stem = name
        for suffix in [".zip", ".fb2"] where stem.lowercased().hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
        }
        return stem.isEmpty ? "Без названия" : stem
    }

    static func message(for error: Error) -> String {
        if let importError = error as? BookImportError { return importError.userMessage }
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoPermission {
            return "Нет доступа к файлу. Попробуйте выбрать его ещё раз."
        }
        return "Не удалось прочитать файл: \(error.localizedDescription)"
    }
}

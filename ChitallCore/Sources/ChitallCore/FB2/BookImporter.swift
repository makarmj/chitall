import Foundation

/// A successfully read book together with the exact bytes Chitall will keep on disk.
public struct ImportedBook: Sendable {
    /// The bytes Chitall keeps: the `.fb2` (unzipped if needed) or the whole `.epub`.
    /// Locators and the fingerprint refer to this content.
    public let sourceData: Data
    public let fingerprint: String
    public let book: ReadableBook
    public let encoding: SourceEncoding
    public let usedEncodingFallback: Bool
    /// Name of the entry inside a `.fb2.zip`, `nil` for a plain `.fb2` and for EPUB.
    public let archiveEntryName: String?

    public var format: BookFormat { book.format }
}

public enum BookImporter {
    public static let maximumFileSize = 150 * 1024 * 1024

    public static func importBook(
        data: Data,
        inflater: ZipArchive.Inflater? = ZipArchive.systemInflater
    ) throws -> ImportedBook {
        guard !data.isEmpty else { throw BookImportError.emptyFile }
        guard data.count <= maximumFileSize else {
            throw BookImportError.fileTooLarge(bytes: data.count, limit: maximumFileSize)
        }

        var source = data
        var entryName: String?
        if ZipArchive.looksLikeZip(data) {
            let archive = try openArchive(data)
            if EPUBParser.isEPUB(archive) {
                let book = try EPUBParser.parse(archive, inflater: inflater)
                return ImportedBook(
                    sourceData: data,
                    fingerprint: Fingerprint.of(data),
                    book: book,
                    encoding: .utf8,
                    usedEncodingFallback: false,
                    archiveEntryName: nil
                )
            }
            (source, entryName) = try extractFB2(from: archive, size: data.count, inflater: inflater)
        }

        let result = try FB2Parser.parse(source)
        return ImportedBook(
            sourceData: source,
            fingerprint: Fingerprint.of(source),
            book: result.book,
            encoding: result.encoding,
            usedEncodingFallback: result.usedEncodingFallback,
            archiveEntryName: entryName
        )
    }

    /// A stored book as the reader opens it: an EPUB container or an (unzipped) FB2 file.
    public static func readStoredBook(
        _ data: Data,
        inflater: ZipArchive.Inflater? = ZipArchive.systemInflater
    ) throws -> ReadableBook {
        if ZipArchive.looksLikeZip(data) {
            return try EPUBParser.parse(openArchive(data), inflater: inflater)
        }
        return try FB2Parser.parse(data).book
    }

    static func openArchive(_ data: Data) throws -> ZipArchive {
        do {
            return try ZipArchive(data: data)
        } catch let failure as ZipArchive.Failure {
            throw importError(failure, size: data.count)
        }
    }

    static func importError(_ failure: ZipArchive.Failure, size: Int) -> BookImportError {
        switch failure {
        case .notAnArchive, .damaged, .checksumMismatch:
            return .damagedArchive(String(describing: failure))
        case let .unsupported(reason):
            return .unsupportedArchive(reason)
        case .tooLarge:
            return .fileTooLarge(bytes: size, limit: maximumFileSize)
        }
    }

    static func extractFB2(from archive: ZipArchive, size: Int, inflater: ZipArchive.Inflater?) throws -> (Data, String) {
        do {
            let candidates = archive.entries.filter { entry in
                !entry.isDirectory
                    && !entry.name.hasPrefix("__MACOSX/")
                    && entry.name.lowercased().hasSuffix(".fb2")
            }
            guard let entry = candidates.max(by: { $0.uncompressedSize < $1.uncompressedSize }) else {
                throw BookImportError.archiveWithoutFB2
            }
            guard entry.uncompressedSize <= maximumFileSize else {
                throw BookImportError.fileTooLarge(bytes: entry.uncompressedSize, limit: maximumFileSize)
            }
            return (try archive.data(for: entry, inflater: inflater), entry.name)
        } catch let failure as ZipArchive.Failure {
            throw importError(failure, size: size)
        }
    }
}

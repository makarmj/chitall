import Foundation

/// A successfully read book together with the exact bytes Chitall will keep on disk.
public struct ImportedBook: Sendable {
    /// The `.fb2` bytes (unzipped if needed). Locators refer to this content.
    public let sourceData: Data
    public let fingerprint: String
    public let book: ReadableBook
    public let encoding: SourceEncoding
    public let usedEncodingFallback: Bool
    /// Name of the entry inside a `.fb2.zip`, `nil` for a plain `.fb2`.
    public let archiveEntryName: String?
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
            (source, entryName) = try extractFB2(from: data, inflater: inflater)
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

    static func extractFB2(from data: Data, inflater: ZipArchive.Inflater?) throws -> (Data, String) {
        do {
            let archive = try ZipArchive(data: data)
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
            switch failure {
            case .notAnArchive, .damaged, .checksumMismatch:
                throw BookImportError.damagedArchive(String(describing: failure))
            case let .unsupported(reason):
                throw BookImportError.unsupportedArchive(reason)
            case .tooLarge:
                throw BookImportError.fileTooLarge(bytes: data.count, limit: maximumFileSize)
            }
        }
    }
}

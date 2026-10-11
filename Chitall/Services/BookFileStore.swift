import Foundation

/// Book files live in Application Support/Chitall: the exact imported `.fb2` bytes (locators
/// refer to them) and extracted covers. Nothing leaves the device.
struct BookFileStore: Sendable {
    let root: URL

    var booksDirectory: URL { root.appendingPathComponent("Books", isDirectory: true) }
    var coversDirectory: URL { root.appendingPathComponent("Covers", isDirectory: true) }

    static func live() throws -> BookFileStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let store = BookFileStore(root: base.appendingPathComponent("Chitall", isDirectory: true))
        try store.prepare()
        return store
    }

    func prepare() throws {
        for directory in [booksDirectory, coversDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// File-system-safe stem: the hex digest without the `sha256:` prefix.
    static func stem(for fingerprint: String) -> String {
        fingerprint.hasPrefix(Fingerprint.prefix) ? String(fingerprint.dropFirst(Fingerprint.prefix.count)) : fingerprint
    }

    func writeBook(_ data: Data, fingerprint: String) throws -> String {
        let name = Self.stem(for: fingerprint) + ".fb2"
        try data.write(to: booksDirectory.appendingPathComponent(name), options: .atomic)
        return name
    }

    func readBook(named name: String) throws -> Data {
        try Data(contentsOf: booksDirectory.appendingPathComponent(name), options: .mappedIfSafe)
    }

    func bookExists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: booksDirectory.appendingPathComponent(name).path)
    }

    /// Saves an embedded cover; returns its file name, or `nil` for unsupported image types.
    func writeCover(_ image: BookImage, fingerprint: String) -> String? {
        let fileExtension: String
        switch image.contentType.lowercased() {
        case "image/jpeg", "image/jpg": fileExtension = "jpg"
        case "image/png": fileExtension = "png"
        case "image/gif": fileExtension = "gif"
        default: return nil
        }
        let name = Self.stem(for: fingerprint) + "." + fileExtension
        do {
            try image.data.write(to: coversDirectory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func coverURL(named name: String) -> URL {
        coversDirectory.appendingPathComponent(name)
    }

    func removeFiles(bookFileName: String, coverFileName: String?) {
        try? FileManager.default.removeItem(at: booksDirectory.appendingPathComponent(bookFileName))
        if let coverFileName {
            try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(coverFileName))
        }
    }

    /// Bytes used by stored books and covers.
    func usedBytes() -> Int {
        var total = 0
        for directory in [booksDirectory, coversDirectory] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            for url in urls {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
        }
        return total
    }
}

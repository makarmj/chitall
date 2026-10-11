import Foundation
#if canImport(Compression)
import Compression
#endif

/// Just enough of the ZIP format to pull a single `.fb2` out of a `.fb2.zip`:
/// end-of-central-directory, central directory, local headers, methods "stored" and "deflate".
/// Not supported (reported as errors): ZIP64, encryption, multi-disk archives, other methods.
public struct ZipArchive: Sendable {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let method: UInt16
        public let flags: UInt16
        public let crc32: UInt32
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int

        public var isDirectory: Bool { name.hasSuffix("/") }
        public var isEncrypted: Bool { flags & 0x0001 != 0 }
    }

    public enum Failure: Error, Equatable, Sendable {
        case notAnArchive
        case damaged(String)
        case unsupported(String)
        case checksumMismatch(String)
        case tooLarge(String)
    }

    /// Decompresses raw DEFLATE data (RFC 1951) into exactly `expectedSize` bytes.
    public typealias Inflater = @Sendable (_ compressed: Data, _ expectedSize: Int) throws -> Data

    public static let localHeaderSignature: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    public static let maximumEntrySize = 256 * 1024 * 1024

    public let entries: [Entry]
    private let bytes: [UInt8]

    public static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && Array(data.prefix(4)) == localHeaderSignature
    }

    public init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        guard bytes.count >= 22 else { throw Failure.notAnArchive }

        // The end-of-central-directory record sits in the last 22 + 65535 (comment) bytes.
        let searchStart = max(0, bytes.count - 22 - 0xFFFF)
        var eocd: Int?
        var position = bytes.count - 22
        while position >= searchStart {
            if Self.readUInt32(bytes, position) == 0x0605_4B50 {
                eocd = position
                break
            }
            position -= 1
        }
        guard let eocd else { throw Failure.notAnArchive }

        let diskNumber = Self.readUInt16(bytes, eocd + 4)
        let centralDisk = Self.readUInt16(bytes, eocd + 6)
        guard diskNumber == 0, centralDisk == 0 else { throw Failure.unsupported("multi-disk archive") }
        let entryCount = Int(Self.readUInt16(bytes, eocd + 10))
        let directorySize = Self.readUInt32(bytes, eocd + 12)
        let directoryOffset = Self.readUInt32(bytes, eocd + 16)
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw Failure.unsupported("ZIP64")
        }
        guard Int(directoryOffset) + Int(directorySize) <= eocd else {
            throw Failure.damaged("central directory is out of bounds")
        }

        var entries: [Entry] = []
        var cursor = Int(directoryOffset)
        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, Self.readUInt32(bytes, cursor) == 0x0201_4B50 else {
                throw Failure.damaged("bad central directory header")
            }
            let flags = Self.readUInt16(bytes, cursor + 8)
            let method = Self.readUInt16(bytes, cursor + 10)
            let crc = Self.readUInt32(bytes, cursor + 16)
            let compressed = Self.readUInt32(bytes, cursor + 20)
            let uncompressed = Self.readUInt32(bytes, cursor + 24)
            let nameLength = Int(Self.readUInt16(bytes, cursor + 28))
            let extraLength = Int(Self.readUInt16(bytes, cursor + 30))
            let commentLength = Int(Self.readUInt16(bytes, cursor + 32))
            let localOffset = Self.readUInt32(bytes, cursor + 42)
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw Failure.unsupported("ZIP64")
            }
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else { throw Failure.damaged("entry name is out of bounds") }
            let nameBytes = Array(bytes[nameStart..<(nameStart + nameLength)])
            let name = String(bytes: nameBytes, encoding: .utf8)
                ?? String(decoding: nameBytes.map { $0 < 0x80 ? $0 : UInt8(ascii: "_") }, as: UTF8.self)
            entries.append(Entry(
                name: name,
                method: method,
                flags: flags,
                crc32: crc,
                compressedSize: Int(compressed),
                uncompressedSize: Int(uncompressed),
                localHeaderOffset: Int(localOffset)
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    public func data(for entry: Entry, inflater: Inflater? = ZipArchive.systemInflater) throws -> Data {
        guard !entry.isEncrypted else { throw Failure.unsupported("encrypted entry") }
        guard entry.uncompressedSize <= Self.maximumEntrySize else { throw Failure.tooLarge(entry.name) }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.readUInt32(bytes, header) == 0x0403_4B50 else {
            throw Failure.damaged("bad local header for \(entry.name)")
        }
        let nameLength = Int(Self.readUInt16(bytes, header + 26))
        let extraLength = Int(Self.readUInt16(bytes, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard end <= bytes.count else { throw Failure.damaged("entry data is out of bounds") }
        let payload = Data(bytes[start..<end])

        let output: Data
        switch entry.method {
        case 0:
            output = payload
        case 8:
            guard let inflater else { throw Failure.unsupported("deflate is not available on this platform") }
            output = try inflater(payload, entry.uncompressedSize)
        default:
            throw Failure.unsupported("compression method \(entry.method)")
        }
        guard output.count == entry.uncompressedSize else {
            throw Failure.damaged("unexpected size of \(entry.name)")
        }
        guard CRC32.checksum(output) == entry.crc32 else {
            throw Failure.checksumMismatch(entry.name)
        }
        return output
    }

    #if canImport(Compression)
    public static let systemInflater: Inflater? = { compressed, expectedSize in
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
            compressed.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP stores.
                return compression_decode_buffer(
                    destinationBase, expectedSize, sourceBase, compressed.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw Failure.damaged("deflate stream") }
        return output
    }
    #else
    public static let systemInflater: Inflater? = nil
    #endif

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

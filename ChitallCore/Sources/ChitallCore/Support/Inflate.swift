import Foundation

/// Raw DEFLATE (RFC 1951) decoder used where Apple's Compression framework is unavailable
/// (Linux, Windows), so that EPUB containers and `.fb2.zip` archives can be read and tested
/// everywhere. On iOS and macOS `ZipArchive.systemInflater` uses Compression instead; the core
/// tests check that both produce the same bytes.
public enum PortableInflate {
    public enum Failure: Error, Equatable, Sendable {
        case truncated
        case invalidBlockType
        case invalidStoredLength
        case invalidCode
        case invalidDistance
        case outputTooLarge
    }

    /// Decompresses `compressed`; stops with an error past `limit` output bytes.
    public static func inflate(_ compressed: Data, limit: Int = ZipArchive.maximumEntrySize) throws -> Data {
        var reader = BitReader(bytes: [UInt8](compressed))
        var output: [UInt8] = []
        var isLast = false
        while !isLast {
            isLast = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0:
                try copyStored(&reader, into: &output, limit: limit)
            case 1:
                try inflateBlock(&reader, literals: fixedLiterals, distances: fixedDistances, into: &output, limit: limit)
            case 2:
                let (literals, distances) = try readDynamicTables(&reader)
                try inflateBlock(&reader, literals: literals, distances: distances, into: &output, limit: limit)
            default:
                throw Failure.invalidBlockType
            }
        }
        return Data(output)
    }

    // MARK: Blocks

    private static func copyStored(_ reader: inout BitReader, into output: inout [UInt8], limit: Int) throws {
        reader.alignToByte()
        let length = try reader.bits(16)
        let complement = try reader.bits(16)
        guard length == ~complement & 0xFFFF else { throw Failure.invalidStoredLength }
        guard output.count + length <= limit else { throw Failure.outputTooLarge }
        output.append(contentsOf: try reader.bytes(length))
    }

    private static let lengthBase: [Int] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtra: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBase: [Int] = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
        4097, 6145, 8193, 12289, 16385, 24577,
    ]
    private static let distanceExtra: [Int] = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    private static func inflateBlock(
        _ reader: inout BitReader,
        literals: Huffman,
        distances: Huffman,
        into output: inout [UInt8],
        limit: Int
    ) throws {
        while true {
            let symbol = try literals.decode(&reader)
            if symbol < 256 {
                guard output.count < limit else { throw Failure.outputTooLarge }
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let lengthIndex = symbol - 257
                guard lengthIndex < lengthBase.count else { throw Failure.invalidCode }
                let length = lengthBase[lengthIndex] + (try reader.bits(lengthExtra[lengthIndex]))
                let distanceSymbol = try distances.decode(&reader)
                guard distanceSymbol < distanceBase.count else { throw Failure.invalidDistance }
                let distance = distanceBase[distanceSymbol] + (try reader.bits(distanceExtra[distanceSymbol]))
                guard distance <= output.count else { throw Failure.invalidDistance }
                guard output.count + length <= limit else { throw Failure.outputTooLarge }
                // Byte by byte: the source may overlap what is being written (distance < length).
                var from = output.count - distance
                for _ in 0..<length {
                    output.append(output[from])
                    from += 1
                }
            }
        }
    }

    private static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static func readDynamicTables(_ reader: inout BitReader) throws -> (Huffman, Huffman) {
        let literalCount = try reader.bits(5) + 257
        let distanceCount = try reader.bits(5) + 1
        let codeLengthCount = try reader.bits(4) + 4
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengths[codeLengthOrder[index]] = try reader.bits(3)
        }
        let codeLengthCode = try Huffman(lengths: codeLengths)

        var lengths: [Int] = []
        let total = literalCount + distanceCount
        while lengths.count < total {
            let symbol = try codeLengthCode.decode(&reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw Failure.invalidCode }
                lengths += Array(repeating: previous, count: 3 + (try reader.bits(2)))
            case 17:
                lengths += Array(repeating: 0, count: 3 + (try reader.bits(3)))
            default:
                lengths += Array(repeating: 0, count: 11 + (try reader.bits(7)))
            }
        }
        guard lengths.count == total, lengths[256] > 0 else { throw Failure.invalidCode }
        return (
            try Huffman(lengths: Array(lengths[0..<literalCount])),
            try Huffman(lengths: Array(lengths[literalCount...]))
        )
    }

    private static let fixedLiterals: Huffman = {
        var lengths = [Int](repeating: 8, count: 288)
        for index in 144..<256 { lengths[index] = 9 }
        for index in 256..<280 { lengths[index] = 7 }
        // swiftlint:disable:next force_try
        return try! Huffman(lengths: lengths)
    }()

    private static let fixedDistances: Huffman = {
        // swiftlint:disable:next force_try
        try! Huffman(lengths: [Int](repeating: 5, count: 30))
    }()

    // MARK: Bits and codes

    struct BitReader {
        let bytes: [UInt8]
        private var position = 0
        private var buffer = 0
        private var count = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        /// The next `n` bits (0…16), least significant first, as DEFLATE packs them.
        mutating func bits(_ n: Int) throws -> Int {
            while count < n {
                guard position < bytes.count else { throw Failure.truncated }
                buffer |= Int(bytes[position]) << count
                position += 1
                count += 8
            }
            let value = buffer & ((1 << n) - 1)
            buffer >>= n
            count -= n
            return value
        }

        mutating func alignToByte() {
            buffer = 0
            count = 0
        }

        mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
            guard position + n <= bytes.count else { throw Failure.truncated }
            defer { position += n }
            return bytes[position..<(position + n)]
        }
    }

    /// Canonical Huffman code, decoded bit by bit (counts per length + symbols in code order).
    struct Huffman {
        private var counts = [Int](repeating: 0, count: 16)
        private var symbols: [Int] = []

        init(lengths: [Int]) throws {
            for length in lengths { counts[length] += 1 }
            counts[0] = 0
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<16 { offsets[length] = offsets[length - 1] + counts[length - 1] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1..<16 {
                code |= try reader.bits(1)
                let count = counts[length]
                if code - first < count { return symbols[index + code - first] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw Failure.invalidCode
        }
    }
}

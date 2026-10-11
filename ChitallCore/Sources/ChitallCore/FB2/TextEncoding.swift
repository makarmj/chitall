import Foundation

/// Encodings Chitall can read. FB2 in the wild is mostly UTF-8 or windows-1251.
public enum SourceEncoding: String, Sendable, Codable, CaseIterable {
    case utf8 = "utf-8"
    case utf16LE = "utf-16le"
    case utf16BE = "utf-16be"
    case windows1251 = "windows-1251"
    case koi8r = "koi8-r"
    case cp866 = "cp866"
    case windows1252 = "windows-1252"
    case isoLatin1 = "iso-8859-1"
}

/// Result of turning source bytes into UTF-8 XML that `XMLParser` reads identically on every platform.
struct DecodedXML {
    let utf8Data: Data
    let encoding: SourceEncoding
    /// True when the declared encoding did not match the bytes and a fallback was used.
    let usedFallback: Bool
}

enum XMLTextDecoder {
    /// Detects the encoding (BOM → XML declaration → UTF-8 validity), decodes the bytes and
    /// rewrites the declaration to UTF-8. libxml2 support for legacy encodings depends on how it
    /// was built (iconv), so the conversion is done here with explicit tables instead.
    static func decode(_ data: Data) throws -> DecodedXML {
        let bytes = [UInt8](data)

        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return try finish(utf8: Data(bytes.dropFirst(3)), encoding: .utf8, usedFallback: false)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return try decodeUTF16(Data(bytes.dropFirst(2)), encoding: .utf16LE)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return try decodeUTF16(Data(bytes.dropFirst(2)), encoding: .utf16BE)
        }
        if bytes.starts(with: [0x3C, 0x00, 0x3F, 0x00]) {
            return try decodeUTF16(data, encoding: .utf16LE)
        }
        if bytes.starts(with: [0x00, 0x3C, 0x00, 0x3F]) {
            return try decodeUTF16(data, encoding: .utf16BE)
        }

        let declared = declaredEncodingLabel(bytes)
        let chosen: SourceEncoding
        if let declared {
            guard let known = Self.encoding(forLabel: declared) else {
                throw BookImportError.unsupportedEncoding(declared)
            }
            chosen = known
        } else {
            chosen = .utf8
        }

        switch chosen {
        case .utf8:
            if String(data: data, encoding: .utf8) != nil {
                return try finish(utf8: data, encoding: .utf8, usedFallback: false)
            }
            // Mislabelled or undeclared legacy Russian text is far more common than any other case.
            let text = decodeSingleByte(bytes, table: SingleByteTables.windows1251)
            return try finish(utf8: Data(text.utf8), encoding: .windows1251, usedFallback: true)
        case .utf16LE, .utf16BE:
            // A UTF-16 declaration readable as ASCII means the file is not really UTF-16.
            if String(data: data, encoding: .utf8) != nil {
                return try finish(utf8: data, encoding: .utf8, usedFallback: true)
            }
            throw BookImportError.unsupportedEncoding(declared ?? "utf-16")
        case .isoLatin1:
            let text = latin1(bytes)
            return try finish(utf8: Data(text.utf8), encoding: .isoLatin1, usedFallback: false)
        case .windows1251, .koi8r, .cp866, .windows1252:
            let text = decodeSingleByte(bytes, table: table(for: chosen))
            return try finish(utf8: Data(text.utf8), encoding: chosen, usedFallback: false)
        }
    }

    static func encoding(forLabel label: String) -> SourceEncoding? {
        switch label.lowercased().trimmingCharacters(in: .whitespaces) {
        case "utf-8", "utf8": return .utf8
        case "utf-16", "utf16", "utf-16le": return .utf16LE
        case "utf-16be": return .utf16BE
        case "windows-1251", "cp1251", "win-1251", "win1251", "x-cp1251", "cp-1251", "windows1251": return .windows1251
        case "koi8-r", "koi8r", "koi8", "cskoi8r": return .koi8r
        case "cp866", "ibm866", "866", "csibm866", "dos-866": return .cp866
        case "windows-1252", "cp1252", "win-1252", "x-cp1252": return .windows1252
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1", "iso_8859-1", "us-ascii", "ascii": return .isoLatin1
        default: return nil
        }
    }

    // MARK: - Private

    private static func decodeUTF16(_ data: Data, encoding: SourceEncoding) throws -> DecodedXML {
        let foundation: String.Encoding = encoding == .utf16LE ? .utf16LittleEndian : .utf16BigEndian
        guard let text = String(data: data, encoding: foundation) else {
            throw BookImportError.unsupportedEncoding(encoding.rawValue)
        }
        return try finish(utf8: Data(text.utf8), encoding: encoding, usedFallback: false)
    }

    private static func finish(utf8: Data, encoding: SourceEncoding, usedFallback: Bool) throws -> DecodedXML {
        DecodedXML(utf8Data: rewriteDeclaration(utf8), encoding: encoding, usedFallback: usedFallback)
    }

    /// Reads `encoding="…"` from an ASCII-compatible `<?xml … ?>` declaration.
    static func declaredEncodingLabel(_ bytes: [UInt8]) -> String? {
        guard let range = declarationRange(bytes) else { return nil }
        let declaration = String(decoding: bytes[range], as: UTF8.self)
        guard let keyRange = declaration.range(of: "encoding") else { return nil }
        var rest = declaration[keyRange.upperBound...].drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        let value = rest.dropFirst().prefix { $0 != quote }
        return value.isEmpty ? nil : String(value)
    }

    /// Byte range of the XML declaration `<?xml … ?>` if the document starts with one.
    private static func declarationRange(_ bytes: [UInt8]) -> Range<Int>? {
        var start = 0
        while start < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[start]) { start += 1 }
        let opening: [UInt8] = Array("<?xml".utf8)
        guard bytes.count >= start + opening.count, Array(bytes[start..<(start + opening.count)]) == opening else {
            return nil
        }
        let limit = min(bytes.count, start + 512)
        var index = start + opening.count
        while index + 1 < limit {
            if bytes[index] == UInt8(ascii: "?"), bytes[index + 1] == UInt8(ascii: ">") {
                return start..<(index + 2)
            }
            index += 1
        }
        return nil
    }

    /// Replaces the declared encoding with UTF-8 (or inserts nothing if there is no declaration).
    private static func rewriteDeclaration(_ utf8: Data) -> Data {
        let bytes = [UInt8](utf8)
        guard let range = declarationRange(bytes) else { return utf8 }
        var declaration = String(decoding: bytes[range], as: UTF8.self)
        if let label = declaredEncodingLabel(bytes),
           let keyRange = declaration.range(of: "encoding"),
           let labelRange = declaration.range(of: label, range: keyRange.upperBound..<declaration.endIndex) {
            declaration.replaceSubrange(labelRange, with: "UTF-8")
        }
        var result = Data(bytes[0..<range.lowerBound])
        result.append(Data(declaration.utf8))
        result.append(Data(bytes[range.upperBound...]))
        return result
    }

    private static func table(for encoding: SourceEncoding) -> [UInt32] {
        switch encoding {
        case .windows1251: return SingleByteTables.windows1251
        case .koi8r: return SingleByteTables.koi8r
        case .cp866: return SingleByteTables.cp866
        case .windows1252: return SingleByteTables.windows1252
        default: return []
        }
    }

    static func decodeSingleByte(_ bytes: [UInt8], table: [UInt32]) -> String {
        // Precompute the UTF-8 form of the 128 high code points once.
        let encodedHigh: [[UInt8]] = table.map { value in
            Array(String(Unicode.Scalar(value).map(Character.init) ?? "\u{FFFD}").utf8)
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            if byte < 0x80 {
                output.append(byte)
            } else {
                output.append(contentsOf: encodedHigh[Int(byte - 0x80)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func latin1(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }
}

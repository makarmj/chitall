import Foundation
import XCTest
@testable import ChitallCore

final class EncodingTests: XCTestCase {
    func testSingleByteTablesMatchKnownCodePoints() {
        XCTAssertEqual(XMLTextDecoder.decodeSingleByte([0xC0, 0xFF, 0xA8, 0xB8, 0x97, 0xAB, 0xBB, 0x85], table: SingleByteTables.windows1251), "АяЁё—«»…")
        XCTAssertEqual(XMLTextDecoder.decodeSingleByte([0xC1, 0xE1, 0xA3, 0xB3], table: SingleByteTables.koi8r), "аАёЁ")
        XCTAssertEqual(XMLTextDecoder.decodeSingleByte([0x80, 0xAF, 0xE0, 0xF0, 0xF1], table: SingleByteTables.cp866), "АпрЁё")
        XCTAssertEqual(XMLTextDecoder.decodeSingleByte([0x80, 0xE9], table: SingleByteTables.windows1252), "€é")
        XCTAssertEqual(XMLTextDecoder.decodeSingleByte(Array("plain ascii".utf8), table: SingleByteTables.windows1251), "plain ascii")
    }

    func testReadsDeclaredEncodingLabel() {
        XCTAssertEqual(XMLTextDecoder.declaredEncodingLabel(Array(#"<?xml version="1.0" encoding="windows-1251"?><a/>"#.utf8)), "windows-1251")
        XCTAssertEqual(XMLTextDecoder.declaredEncodingLabel(Array("  <?xml version='1.0' encoding = 'koi8-r' ?><a/>".utf8)), "koi8-r")
        XCTAssertNil(XMLTextDecoder.declaredEncodingLabel(Array(#"<?xml version="1.0"?><a/>"#.utf8)))
        XCTAssertNil(XMLTextDecoder.declaredEncodingLabel(Array("<a/>".utf8)))
    }

    func testEncodingLabelsAreCaseInsensitiveAndAliased() {
        XCTAssertEqual(XMLTextDecoder.encoding(forLabel: "Windows-1251"), .windows1251)
        XCTAssertEqual(XMLTextDecoder.encoding(forLabel: "CP1251"), .windows1251)
        XCTAssertEqual(XMLTextDecoder.encoding(forLabel: "KOI8-R"), .koi8r)
        XCTAssertEqual(XMLTextDecoder.encoding(forLabel: "ibm866"), .cp866)
        XCTAssertEqual(XMLTextDecoder.encoding(forLabel: "UTF8"), .utf8)
        XCTAssertNil(XMLTextDecoder.encoding(forLabel: "shift_jis"))
    }

    func testWindows1251FixtureDecodesLikeUTF8Fixture() throws {
        let utf8 = try FB2Parser.parse(Fixtures.data("sample-utf8.fb2"))
        let cp1251 = try FB2Parser.parse(Fixtures.data("sample-cp1251.fb2"))
        XCTAssertEqual(utf8.encoding, .utf8)
        XCTAssertEqual(cp1251.encoding, .windows1251)
        XCTAssertFalse(cp1251.usedEncodingFallback)
        XCTAssertEqual(cp1251.book.metadata, utf8.book.metadata)
        XCTAssertEqual(cp1251.book.allBlocks, utf8.book.allBlocks)
    }

    func testKOI8RDeclaredDocument() throws {
        let xml = #"<?xml version="1.0" encoding="koi8-r"?><FictionBook><body><section><p>"# + "\u{0001}" + "</p></section></body></FictionBook>"
        var bytes = Array(xml.utf8)
        // Replace the placeholder with "Ёж" in KOI8-R: Ё = 0xB3, ж = 0xD6.
        let placeholder = bytes.firstIndex(of: 0x01)!
        bytes.replaceSubrange(placeholder...placeholder, with: [0xB3, 0xD6])
        let book = try parse(Data(bytes))
        XCTAssertEqual(book.allBlocks.first?.text, "Ёж")
    }

    func testUTF8BOMAndUTF16BOM() throws {
        let xml = #"<?xml version="1.0" encoding="UTF-8"?><FictionBook><body><section><p>Пыль</p></section></body></FictionBook>"#
        let withBOM = Data([0xEF, 0xBB, 0xBF]) + Data(xml.utf8)
        XCTAssertEqual(try parse(withBOM).allBlocks.first?.text, "Пыль")

        let utf16 = Data([0xFF, 0xFE]) + xml.replacingOccurrences(of: "UTF-8", with: "UTF-16").data(using: .utf16LittleEndian)!
        let result = try FB2Parser.parse(utf16)
        XCTAssertEqual(result.encoding, .utf16LE)
        XCTAssertEqual(result.book.allBlocks.first?.text, "Пыль")
    }

    func testUndeclaredInvalidUTF8FallsBackToWindows1251() throws {
        var bytes = Array("<FictionBook><body><section><p>".utf8)
        bytes += [0xCF, 0xE5, 0xF7, 0xE0, 0xF2, 0xFC] // "Печать" in windows-1251
        bytes += Array("</p></section></body></FictionBook>".utf8)
        let result = try FB2Parser.parse(Data(bytes))
        XCTAssertEqual(result.encoding, .windows1251)
        XCTAssertTrue(result.usedEncodingFallback)
        XCTAssertEqual(result.book.allBlocks.first?.text, "Печать")
    }

    func testUnknownEncodingIsAClearError() {
        let data = Data(#"<?xml version="1.0" encoding="shift_jis"?><FictionBook/>"#.utf8)
        XCTAssertThrowsImportError(try FB2Parser.parse(data), .unsupportedEncoding("shift_jis"))
    }
}

import Foundation
import XCTest
@testable import ChitallCore

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    static func sampleBook() throws -> ReadableBook {
        try FB2Parser.parse(data("sample-utf8.fb2")).book
    }
}

/// Wraps body content into a minimal valid FB2 document.
func fb2(body: String, notes: String? = nil, declaration: String = #"<?xml version="1.0" encoding="UTF-8"?>"#) -> Data {
    var xml = declaration + "\n"
    xml += #"<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">"#
    xml += "<description><title-info><book-title>Тест</book-title></title-info></description>"
    xml += "<body>\(body)</body>"
    if let notes { xml += #"<body name="notes">\#(notes)</body>"# }
    xml += "</FictionBook>"
    return Data(xml.utf8)
}

func parse(_ data: Data) throws -> ReadableBook {
    try FB2Parser.parse(data).book
}

/// UTF-16 offset of the first occurrence of `needle`, as NSString.range(of:) would report it.
func utf16Offset(of needle: String, in haystack: String) -> Int? {
    guard let range = haystack.range(of: needle) else { return nil }
    return haystack.utf16.distance(from: haystack.startIndex, to: range.lowerBound)
}

extension ReadableBook {
    func block(path: String) -> Block? {
        ordinal(of: TextAnchor(path: path)).flatMap { block($0) }
    }

    var allBlocks: [Block] { chapters.flatMap(\.blocks) }
}

func XCTAssertThrowsImportError(
    _ expression: @autoclosure () throws -> some Any,
    _ expected: BookImportError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(try expression(), file: file, line: line) { error in
        XCTAssertEqual(error as? BookImportError, expected, file: file, line: line)
    }
}

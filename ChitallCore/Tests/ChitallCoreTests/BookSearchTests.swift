import Foundation
import XCTest
@testable import ChitallCore

final class BookSearchTests: XCTestCase {
    func testFindsAllOccurrencesAcrossChaptersInReadingOrder() throws {
        let book = try Fixtures.sampleBook()
        let result = BookSearch.search("ефим", in: book)
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.hits.map(\.chapterIndex), [1, 2])
        for hit in result.hits {
            XCTAssertEqual(book.text(in: hit.range), "Ефим")
            XCTAssertEqual(hit.match, "Ефим")
        }
        XCTAssertEqual(result.hits.map(\.range.start.block), result.hits.map(\.range.start.block).sorted())
    }

    func testCaseAndYoInsensitive() throws {
        let book = try parse(fb2(body: "<section><p>Ещё раз, ЕЩЕ раз, ещё.</p></section>"))
        let result = BookSearch.search("еще", in: book)
        XCTAssertEqual(result.hits.map(\.match), ["Ещё", "ЕЩЕ", "ещё"])
        XCTAssertEqual(result.hits.map(\.range.start.offset), [0, 9, 18])
    }

    func testRepeatedLettersAreFoundWithoutOverlap() throws {
        // The case from the first device test: searching "ее" in Russian text.
        let book = try parse(fb2(body: "<section><p>Ее нет. Её видели. Длиннее.</p></section>"))
        let hits = BookSearch.search("ее", in: book).hits
        XCTAssertEqual(hits.map(\.match), ["Ее", "Её", "ее"])
    }

    func testSnippetsShowContextWithEllipsis() throws {
        let book = try Fixtures.sampleBook()
        let hit = try XCTUnwrap(BookSearch.search("белый", in: book).hits.first)
        XCTAssertTrue(hit.before.hasPrefix("…"))
        XCTAssertTrue(hit.before.hasSuffix("уже стоял "))
        XCTAssertTrue(hit.after.hasPrefix(" туман."))
        XCTAssertLessThanOrEqual(hit.before.unicodeScalars.count, BookSearch.contextLength + 1)
    }

    func testQueryWhitespaceIsCollapsedLikeCanonicalText() throws {
        let book = try Fixtures.sampleBook()
        XCTAssertEqual(BookSearch.search("  белый \n туман ", in: book).hits.count, 1)
    }

    func testEmptyQueryAndLimit() throws {
        let book = try Fixtures.sampleBook()
        XCTAssertTrue(BookSearch.search("   ", in: book).hits.isEmpty)
        let limited = BookSearch.search("о", in: book, limit: 5)
        XCTAssertEqual(limited.hits.count, 5)
        XCTAssertTrue(limited.isTruncated)
    }

    func testOffsetsStayExactWithAstralCharacters() throws {
        let book = try parse(fb2(body: "<section><p>🧂Соль и 𝔄соль</p></section>"))
        let hits = BookSearch.search("соль", in: book).hits
        // 🧂 and 𝔄 are one scalar each (two UTF-16 units on screen).
        XCTAssertEqual(hits.map(\.range.start.offset), [1, 9])
        XCTAssertEqual(hits.map { book.text(in: $0.range) }, ["Соль", "соль"])
    }
}

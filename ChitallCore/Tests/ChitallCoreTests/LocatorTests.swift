import Foundation
import XCTest
@testable import ChitallCore

final class LocatorTests: XCTestCase {
    private var sampleData: Data!
    private var book: ReadableBook!
    private var service: LocatorService!

    /// "Ефим снял шапку и долго смотрел на огни.[1]\n— Соль" across the empty line.
    private let selection = BlockRange(start: BlockPosition(block: 7, offset: 15), end: BlockPosition(block: 9, offset: 6))

    override func setUpWithError() throws {
        sampleData = try Fixtures.data("sample-utf8.fb2")
        book = try parse(sampleData)
        service = LocatorService(book: book, fingerprint: Fingerprint.of(sampleData))
    }

    func testLocatorDescribesSourcePathsOffsetsAndQuote() throws {
        let locator = try XCTUnwrap(service.locator(for: selection))
        XCTAssertEqual(locator.v, 1)
        XCTAssertEqual(locator.format, .fb2)
        XCTAssertEqual(locator.book, Fingerprint.of(sampleData))
        XCTAssertTrue(locator.book.hasPrefix("sha256:"))
        XCTAssertEqual(locator.chapter, 1)
        XCTAssertEqual(locator.start, Locator.Point(path: "/FictionBook/body[1]/section[1]/p[2]", offset: 15))
        XCTAssertEqual(locator.end, Locator.Point(path: "/FictionBook/body[1]/section[1]/p[3]", offset: 6))
        XCTAssertEqual(locator.quote?.exact, "Ефим снял шапку и долго смотрел на огни.[1]\n— Соль")
        XCTAssertEqual(locator.quote?.prefix.unicodeScalars.count, Locator.contextLength)
        XCTAssertTrue(locator.quote?.prefix.hasSuffix("белый туман.\nСтарший возчик ") ?? false)
        XCTAssertTrue(locator.quote?.suffix.hasPrefix(" везём, — сказал он стражнику.") ?? false)
        XCTAssertGreaterThan(locator.progression, 0)
        XCTAssertLessThan(locator.progression, 1)
    }

    func testJSONRoundTripAndShape() throws {
        let locator = try XCTUnwrap(service.locator(for: selection))
        let json = try locator.jsonString()
        XCTAssertEqual(try Locator.fromJSONString(json), locator)
        XCTAssertTrue(json.hasPrefix(#"{"book":"sha256:"#))
        XCTAssertTrue(json.contains(#""start":{"offset":15,"path":"/FictionBook/body[1]/section[1]/p[2]"}"#))
        XCTAssertTrue(json.contains(#""v":1"#))
        XCTAssertFalse(json.contains("resource"), "FB2 locators omit the container resource")
    }

    func testNewerLocatorVersionIsRejected() {
        let json = #"{"book":"sha256:00","chapter":0,"format":"fb2","progression":0,"start":{"offset":0,"path":"/FictionBook/body[1]/section[1]/p[1]"},"v":2}"#
        XCTAssertThrowsError(try Locator.fromJSONString(json)) { error in
            XCTAssertEqual(error as? LocatorError, .unsupportedVersion(2))
        }
    }

    func testResolvesExactlyInSameBookAndAfterReparse() throws {
        let locator = try XCTUnwrap(service.locator(for: selection))
        XCTAssertEqual(service.resolve(locator), .exact(selection))
        let reparsed = LocatorService(book: try parse(sampleData), fingerprint: Fingerprint.of(sampleData))
        XCTAssertEqual(reparsed.resolve(locator), .exact(selection))
    }

    func testSurvivesReformattedXML() throws {
        let locator = try XCTUnwrap(service.locator(for: selection))
        let reformatted = String(decoding: sampleData, as: UTF8.self)
            .replacingOccurrences(of: "<p>", with: "<p>\n          ")
            .replacingOccurrences(of: "</p>", with: "\n        </p>")
            .replacingOccurrences(of: "\n  ", with: "\n\t")
        let data = Data(reformatted.utf8)
        XCTAssertNotEqual(Fingerprint.of(data), locator.book)
        let other = LocatorService(book: try parse(data), fingerprint: Fingerprint.of(data))
        XCTAssertEqual(other.resolve(locator), .exact(selection))
    }

    func testSurvivesReencodingToWindows1251() throws {
        let locator = try XCTUnwrap(service.locator(for: selection))
        let data = try Fixtures.data("sample-cp1251.fb2")
        let other = LocatorService(book: try parse(data), fingerprint: Fingerprint.of(data))
        XCTAssertEqual(other.resolve(locator), .exact(selection))
    }

    func testRelocatesAfterParagraphInsertedBefore() throws {
        let locator = try XCTUnwrap(service.locator(for: selection))
        let edited = String(decoding: sampleData, as: UTF8.self).replacingOccurrences(
            of: "<p>Застава</p>\n      </title>",
            with: "<p>Застава</p>\n      </title>\n      <p>Новый абзац, добавленный редактором.</p>"
        )
        let editedBook = try parse(Data(edited.utf8))
        let other = LocatorService(book: editedBook, fingerprint: Fingerprint.of(Data(edited.utf8)))
        guard case let .relocated(range) = other.resolve(locator) else {
            return XCTFail("expected relocation, got \(other.resolve(locator))")
        }
        XCTAssertEqual(range.start, BlockPosition(block: 8, offset: 15))
        XCTAssertEqual(editedBook.block(range.start.block)?.anchor.path, "/FictionBook/body[1]/section[1]/p[3]")
        XCTAssertEqual(editedBook.text(in: range), locator.quote?.exact)
    }

    func testReportsNotFoundWhenTextIsGone() throws {
        let locator = try XCTUnwrap(service.locator(for: selection))
        let edited = String(decoding: sampleData, as: UTF8.self).replacingOccurrences(
            of: "<p>— Соль везём, — сказал он стражнику. — <strong>Казённую</strong>.</p>",
            with: ""
        )
        let other = LocatorService(book: try parse(Data(edited.utf8)), fingerprint: "sha256:edited")
        XCTAssertEqual(other.resolve(locator), .notFound)
    }

    func testAmbiguousQuoteIsDisambiguatedByContext() throws {
        let original = try parse(fb2(body: "<section><p>Он сказал: да.</p><p>Она сказала: да.</p></section>"))
        let originalService = LocatorService(book: original, fingerprint: "sha256:a")
        let second = BlockRange(start: BlockPosition(block: 1, offset: 13), end: BlockPosition(block: 1, offset: 15))
        let locator = try XCTUnwrap(originalService.locator(for: second))
        XCTAssertEqual(locator.quote?.exact, "да")

        let edited = try parse(fb2(body: "<section><p>Вступление.</p><p>Он сказал: да.</p><p>Она сказала: да.</p></section>"))
        let editedService = LocatorService(book: edited, fingerprint: "sha256:b")
        XCTAssertEqual(editedService.resolve(locator), .relocated(BlockRange(
            start: BlockPosition(block: 2, offset: 13),
            end: BlockPosition(block: 2, offset: 15)
        )))

        // Without any context a two-letter quote that occurs twice is not trusted.
        var bare = locator
        bare.quote = Locator.Quote(exact: "да", prefix: "", suffix: "")
        bare.start.path = "/FictionBook/body[1]/section[1]/p[9]"
        XCTAssertEqual(editedService.resolve(bare), .notFound)
    }

    func testCaretLocatorForReadingPosition() throws {
        let position = BlockPosition(block: 19, offset: 5)
        let locator = try XCTUnwrap(service.locator(at: position))
        XCTAssertNil(locator.end)
        XCTAssertNil(locator.quote)
        XCTAssertEqual(locator.chapter, 2)
        XCTAssertEqual(service.resolve(locator), .caret(position))

        var lost = locator
        lost.start.path = "/FictionBook/body[1]/section[9]/p[1]"
        guard case let .caret(fallback) = service.resolve(lost) else { return XCTFail("expected caret") }
        XCTAssertEqual(book.progression(of: fallback), locator.progression, accuracy: 0.01)
    }

    func testProgressionIsMonotonicAcrossTheBook() throws {
        var previous = -1.0
        for block in book.allBlocks where block.hasText {
            let value = book.progression(of: BlockPosition(block: block.ordinal, offset: 0))
            XCTAssertGreaterThan(value, previous)
            XCTAssertLessThanOrEqual(value, 1)
            previous = value
        }
        XCTAssertEqual(book.progression(of: BlockPosition(block: 0, offset: 0)), 0)
    }

    func testOffsetsAreUnicodeScalars() throws {
        let astral = try parse(fb2(body: "<section><p>А𝔄Б🧂В</p></section>"))
        let text = ChapterText(chapter: astral.chapters[0])
        let range = try XCTUnwrap(text.blockRange(forUTF16: 3..<6))
        let locator = try XCTUnwrap(LocatorService(book: astral, fingerprint: "sha256:x").locator(for: range))
        XCTAssertEqual(locator.start.offset, 2)
        XCTAssertEqual(locator.end?.offset, 4)
        XCTAssertEqual(locator.quote?.exact, "Б🧂")
    }

    func testLocatorsInsideNotes() throws {
        let note = BlockRange(start: BlockPosition(block: 24, offset: 0), end: BlockPosition(block: 24, offset: 4))
        let locator = try XCTUnwrap(service.locator(for: note))
        XCTAssertEqual(locator.chapter, 3)
        XCTAssertEqual(locator.start.path, "/FictionBook/body[2]/section[1]/p[1]")
        XCTAssertEqual(locator.quote?.exact, "Огни")
    }

    func testEmptyOrInvertedRangesProduceNoLocator() {
        XCTAssertNil(service.locator(for: BlockRange(start: BlockPosition(block: 7, offset: 5), end: BlockPosition(block: 7, offset: 5))))
        XCTAssertNil(service.locator(for: BlockRange(start: BlockPosition(block: 9, offset: 0), end: BlockPosition(block: 7, offset: 0))))
        XCTAssertNil(service.locator(for: BlockRange(start: BlockPosition(block: 7, offset: 0), end: BlockPosition(block: 7, offset: 999))))
    }
}

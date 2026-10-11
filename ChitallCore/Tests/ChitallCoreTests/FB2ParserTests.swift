import Foundation
import XCTest
@testable import ChitallCore

final class FB2ParserTests: XCTestCase {
    func testMetadata() throws {
        let metadata = try Fixtures.sampleBook().metadata
        XCTAssertEqual(metadata.title, "Соляной обоз")
        XCTAssertEqual(metadata.authors, [Person(firstName: "Анна", lastName: "Тестова")])
        XCTAssertEqual(metadata.authorLine, "Анна Тестова")
        XCTAssertEqual(metadata.genres, ["prose_history"])
        XCTAssertEqual(metadata.keywords, ["соль", "обоз", "зима"])
        XCTAssertEqual(metadata.language, "ru")
        XCTAssertEqual(metadata.date, "2026")
        XCTAssertEqual(metadata.annotation, "Короткая книга для проверки Chitall.\nТекст написан специально для тестов.")
        XCTAssertEqual(metadata.series, BookSeries(name: "Пробные книги", number: "1"))
        XCTAssertEqual(metadata.coverImageID, "cover.png")
        XCTAssertEqual(metadata.documentID, "chitall-test-0001")
        XCTAssertEqual(metadata.documentVersion, "1.0")
    }

    func testChaptersFollowTopLevelSectionsAndNotesBody() throws {
        let book = try Fixtures.sampleBook()
        XCTAssertEqual(book.chapters.map(\.title), [
            "Анна Тестова. Соляной обоз",
            "Глава первая. Застава",
            "Глава вторая",
            "Примечания",
        ])
        XCTAssertEqual(book.chapters.map(\.isNotes), [false, false, false, true])
        XCTAssertEqual(book.chapters.map(\.anchor.path), [
            "/FictionBook/body[1]",
            "/FictionBook/body[1]/section[1]",
            "/FictionBook/body[1]/section[2]",
            "/FictionBook/body[2]",
        ])
        XCTAssertEqual(book.chapters[1].tableOfContents, [TOCEntry(title: "Ночь у ворот", depth: 1, firstBlock: 10)])
    }

    func testBlockPathsRolesAndOrdinals() throws {
        let book = try Fixtures.sampleBook()
        let blocks = book.allBlocks
        XCTAssertEqual(blocks.map(\.ordinal), Array(0..<blocks.count))
        XCTAssertEqual(blocks.count, 27)

        let expected: [(String, BlockRole, String)] = [
            ("/FictionBook/body[1]/title[1]/p[1]", .title, "Анна Тестова"),
            ("/FictionBook/body[1]/title[1]/p[2]", .title, "Соляной обоз"),
            ("/FictionBook/body[1]/epigraph[1]/p[1]", .paragraph, "Дорога помнит всех, кто по ней шёл."),
            ("/FictionBook/body[1]/epigraph[1]/text-author[1]", .textAuthor, "Надпись на верстовом столбе"),
            ("/FictionBook/body[1]/section[1]/title[1]/p[1]", .title, "Глава первая"),
            ("/FictionBook/body[1]/section[1]/title[1]/p[2]", .title, "Застава"),
            ("/FictionBook/body[1]/section[1]/p[1]", .paragraph, "Обоз подошёл к заставе в сумерках, когда над рекой уже стоял белый туман."),
            ("/FictionBook/body[1]/section[1]/p[2]", .paragraph, "Старший возчик Ефим снял шапку и долго смотрел на огни.[1]"),
            ("/FictionBook/body[1]/section[1]/empty-line[1]", .emptyLine, ""),
            ("/FictionBook/body[1]/section[1]/p[3]", .paragraph, "— Соль везём, — сказал он стражнику. — Казённую."),
            ("/FictionBook/body[1]/section[1]/section[1]/title[1]/p[1]", .title, "Ночь у ворот"),
            ("/FictionBook/body[1]/section[1]/section[1]/p[1]", .paragraph, "Ночью лаяли собаки, и никто не спал."),
            ("/FictionBook/body[1]/section[1]/section[1]/poem[1]/title[1]/p[1]", .subtitle, "Песня возчиков"),
            ("/FictionBook/body[1]/section[1]/section[1]/poem[1]/stanza[1]/v[1]", .verse, "Снег по колено, соль по плечо,"),
            ("/FictionBook/body[1]/section[1]/section[1]/poem[1]/stanza[1]/v[2]", .verse, "Доедем до света — будет горячо."),
            ("/FictionBook/body[1]/section[1]/section[1]/poem[1]/text-author[1]", .textAuthor, "народное"),
            ("/FictionBook/body[1]/section[2]/title[1]/p[1]", .title, "Глава вторая"),
            ("/FictionBook/body[1]/section[2]/cite[1]/p[1]", .paragraph, "«Всякий товар, ввозимый в город, досматривается»."),
            ("/FictionBook/body[1]/section[2]/cite[1]/text-author[1]", .textAuthor, "Уставная грамота"),
            ("/FictionBook/body[1]/section[2]/p[1]", .paragraph, "Утром пришёл писарь с печатью.[2] Он пересчитал мешки дважды."),
            ("/FictionBook/body[1]/section[2]/p[2]", .paragraph, "Один мешок оказался легче остальных."),
            ("/FictionBook/body[1]/section[2]/p[3]", .paragraph, "Ефим промолчал."),
            ("/FictionBook/body[2]/title[1]/p[1]", .title, "Примечания"),
            ("/FictionBook/body[2]/section[1]/title[1]/p[1]", .title, "1"),
            ("/FictionBook/body[2]/section[1]/p[1]", .paragraph, "Огни заставы видны с реки за две версты."),
            ("/FictionBook/body[2]/section[2]/title[1]/p[1]", .title, "2"),
            ("/FictionBook/body[2]/section[2]/p[1]", .paragraph, "Писарь — служащий таможенной избы."),
        ]
        XCTAssertEqual(blocks.count, expected.count)
        for (block, (path, role, text)) in zip(blocks, expected) {
            XCTAssertEqual(block.anchor.path, path)
            XCTAssertEqual(block.role, role, path)
            XCTAssertEqual(block.text, text, path)
            XCTAssertNil(block.anchor.resource)
        }
    }

    func testContextsAndTitleLevels() throws {
        let book = try Fixtures.sampleBook()
        XCTAssertEqual(book.block(path: "/FictionBook/body[1]/title[1]/p[1]")?.titleLevel, 0)
        XCTAssertEqual(book.block(path: "/FictionBook/body[1]/section[1]/title[1]/p[1]")?.titleLevel, 1)
        XCTAssertEqual(book.block(path: "/FictionBook/body[1]/section[1]/section[1]/title[1]/p[1]")?.titleLevel, 2)
        XCTAssertEqual(book.block(path: "/FictionBook/body[1]/epigraph[1]/p[1]")?.context, .epigraph)
        XCTAssertEqual(book.block(path: "/FictionBook/body[1]/section[2]/cite[1]/p[1]")?.context, .cite)
        XCTAssertEqual(book.block(path: "/FictionBook/body[1]/section[1]/section[1]/poem[1]/stanza[1]/v[1]")?.context, .poem)
        XCTAssertEqual(book.block(path: "/FictionBook/body[2]/section[1]/p[1]")?.context, .notes)
    }

    func testInlineRunsUseUTF16RangesOfCanonicalText() throws {
        let book = try Fixtures.sampleBook()
        let first = try XCTUnwrap(book.block(path: "/FictionBook/body[1]/section[1]/p[1]"))
        let emphasis = try XCTUnwrap(first.runs.first)
        XCTAssertEqual(emphasis.style, .emphasis)
        let utf16 = Array(first.text.utf16)
        XCTAssertEqual(String(decoding: utf16[emphasis.range], as: UTF16.self), "белый")

        let withNote = try XCTUnwrap(book.block(path: "/FictionBook/body[1]/section[1]/p[2]"))
        let note = try XCTUnwrap(withNote.runs.first { $0.isNoteReference })
        XCTAssertEqual(note.link, "n1")
        XCTAssertEqual(String(decoding: Array(withNote.text.utf16)[note.range], as: UTF16.self), "[1]")

        let strong = try XCTUnwrap(book.block(path: "/FictionBook/body[1]/section[1]/p[3]")?.runs.first)
        XCTAssertEqual(strong.style, .strong)
    }

    func testNotesAndIdTargets() throws {
        let book = try Fixtures.sampleBook()
        XCTAssertEqual(book.notes["n1"]?.title, "1")
        XCTAssertEqual(book.notes["n1"]?.text, "Огни заставы видны с реки за две версты.")
        XCTAssertEqual(book.notes["n2"]?.text, "Писарь — служащий таможенной избы.")
        XCTAssertEqual(book.notes["n2"]?.chapterIndex, 3)
        XCTAssertEqual(book.idTargets["ch2"], 16)
        XCTAssertEqual(book.idTargets["ch1-1"], 10)
    }

    func testCoverImageIsDecoded() throws {
        let cover = try XCTUnwrap(Fixtures.sampleBook().images["cover.png"])
        XCTAssertEqual(cover.contentType, "image/png")
        XCTAssertEqual(Array(cover.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testWhitespaceCanonicalization() throws {
        let book = try parse(fb2(body: "<section><p>\n   Раз\t\tдва\r\n <emphasis> три </emphasis>  че\u{00AD}тыре\u{00A0}пять  \n</p></section>"))
        let block = try XCTUnwrap(book.allBlocks.first)
        XCTAssertEqual(block.text, "Раз два три четыре\u{00A0}пять")
        let emphasis = try XCTUnwrap(block.runs.first)
        // The space before "три" was outside <emphasis>, the one after it inside.
        XCTAssertEqual(String(decoding: Array(block.text.utf16)[emphasis.range], as: UTF16.self), "три ")
    }

    func testPrefixedNamespacesAndXlinkAttributes() throws {
        let xml = #"""
        <?xml version="1.0" encoding="utf-8"?>
        <fb:FictionBook xmlns:fb="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:xlink="http://www.w3.org/1999/xlink">
          <fb:body><fb:section><fb:p>Текст<fb:a xlink:href="#n1" type="note">1</fb:a></fb:p></fb:section></fb:body>
        </fb:FictionBook>
        """#
        let book = try parse(Data(xml.utf8))
        let block = try XCTUnwrap(book.allBlocks.first)
        XCTAssertEqual(block.anchor.path, "/FictionBook/body[1]/section[1]/p[1]")
        XCTAssertEqual(block.runs.first?.link, "n1")
        XCTAssertEqual(block.runs.first?.isNoteReference, true)
    }

    func testStrayTextInsideSectionBecomesParagraph() throws {
        let book = try parse(fb2(body: "<section><p>Абзац</p>Текст без абзаца<p>Ещё</p></section>"))
        XCTAssertEqual(book.allBlocks.map(\.anchor.path), [
            "/FictionBook/body[1]/section[1]/p[1]",
            "/FictionBook/body[1]/section[1]/text()[1]",
            "/FictionBook/body[1]/section[1]/p[2]",
        ])
        XCTAssertEqual(book.allBlocks[1].text, "Текст без абзаца")
    }

    func testSingleWrappingSectionIsUnwrappedIntoChapters() throws {
        let book = try parse(fb2(body: """
            <section><title><p>Часть первая</p></title>
              <section><title><p>Один</p></title><p>а</p></section>
              <section><title><p>Два</p></title><p>б</p></section>
            </section>
            """))
        XCTAssertEqual(book.chapters.map(\.title), ["Часть первая", "Один", "Два"])
        XCTAssertEqual(book.chapters[1].anchor.path, "/FictionBook/body[1]/section[1]/section[1]")
    }

    func testSectionsWithoutTitlesGetNumberedNames() throws {
        let book = try parse(fb2(body: "<section><p>а</p></section><section><p>б</p></section>"))
        XCTAssertEqual(book.chapters.map(\.title), ["Раздел 1", "Раздел 2"])
    }

    func testTablesAndImages() throws {
        let book = try parse(fb2(body: ##"<section><image l:href="#pic"/><table><tr><th>Год</th><td>1612</td></tr></table></section>"##))
        XCTAssertEqual(book.allBlocks.map(\.role), [.image, .tableCell, .tableCell])
        XCTAssertEqual(book.allBlocks[0].imageID, "pic")
        XCTAssertEqual(book.allBlocks[2].anchor.path, "/FictionBook/body[1]/section[1]/table[1]/tr[1]/td[1]")
    }

    func testSampleBookShippedWithTheAppParses() throws {
        let url = Fixtures.directory
            .deletingLastPathComponent() // ChitallCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ChitallCore
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Chitall/Resources/SampleBooks/chitall-sample.fb2")
        let book = try parse(Data(contentsOf: url))
        XCTAssertEqual(book.metadata.title, "Соляной обоз")
        XCTAssertEqual(book.chapters.map(\.title), [
            "Соляной обоз",
            "Глава первая. Застава",
            "Глава вторая. Досмотр",
            "Глава третья. Мешок",
            "Глава четвёртая. Город",
            "Примечания",
        ])
        XCTAssertEqual(book.notes.count, 2)
        XCTAssertEqual(book.chapters[1].tableOfContents.map(\.title), ["Ночь у ворот"])
    }

    func testReparsingProducesIdenticalModel() throws {
        let data = try Fixtures.data("sample-utf8.fb2")
        XCTAssertEqual(try parse(data).allBlocks, try parse(data).allBlocks)
    }

    // MARK: Errors

    func testEmptyAndWhitespaceFiles() {
        XCTAssertThrowsImportError(try FB2Parser.parse(Data()), .emptyFile)
        XCTAssertThrowsImportError(try FB2Parser.parse(Data("  \n\t ".utf8)), .emptyFile)
    }

    func testNotXML() {
        XCTAssertThrowsError(try FB2Parser.parse(Data("это просто текст, не XML".utf8))) { error in
            guard case .malformedXML = error as? BookImportError else {
                return XCTFail("expected malformedXML, got \(error)")
            }
        }
    }

    func testTruncatedFile() throws {
        let data = try Fixtures.data("sample-utf8.fb2")
        let truncated = data.prefix(data.count / 2)
        XCTAssertThrowsError(try FB2Parser.parse(truncated)) { error in
            guard case let .malformedXML(line, _, _) = error as? BookImportError else {
                return XCTFail("expected malformedXML, got \(error)")
            }
            XCTAssertGreaterThan(line, 1)
        }
    }

    func testWrongRootElement() {
        XCTAssertThrowsImportError(try FB2Parser.parse(Data("<html><body><p>x</p></body></html>".utf8)), .notFictionBook(rootElement: "html"))
    }

    func testNoBody() {
        XCTAssertThrowsImportError(try FB2Parser.parse(Data("<FictionBook><description/></FictionBook>".utf8)), .noBody)
    }

    func testNoText() {
        XCTAssertThrowsImportError(try FB2Parser.parse(fb2(body: "<section><p>  </p><empty-line/></section>")), .noText)
    }

    func testErrorsHaveRussianMessages() {
        XCTAssertEqual(BookImportError.noBody.userMessage, "В книге нет текста: отсутствует раздел body.")
        XCTAssertTrue(BookImportError.malformedXML(line: 3, column: 7, reason: "x").userMessage.contains("строке 3"))
    }
}

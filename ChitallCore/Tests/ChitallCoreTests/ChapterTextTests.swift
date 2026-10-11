import Foundation
import XCTest
@testable import ChitallCore

final class ChapterTextTests: XCTestCase {
    func testChapterStringIsBlocksJoinedByNewlines() throws {
        let book = try Fixtures.sampleBook()
        let text = ChapterText(chapter: book.chapters[2])
        XCTAssertEqual(text.string, """
            Глава вторая
            «Всякий товар, ввозимый в город, досматривается».
            Уставная грамота
            Утром пришёл писарь с печатью.[2] Он пересчитал мешки дважды.
            Один мешок оказался легче остальных.
            Ефим промолчал.
            """)
        XCTAssertEqual(text.utf16Length, text.string.utf16.count)
    }

    func testSegmentsCoverExactlyTheBlockText() throws {
        let book = try Fixtures.sampleBook()
        for chapter in book.chapters {
            let text = ChapterText(chapter: chapter)
            let utf16 = Array(text.string.utf16)
            for segment in text.segments {
                let content = String(decoding: utf16[segment.range], as: UTF16.self)
                switch segment.block.role {
                case .image: XCTAssertEqual(content, ChapterText.attachmentCharacter)
                case .emptyLine: XCTAssertEqual(content, "")
                default: XCTAssertEqual(content, segment.block.text)
                }
            }
            for run in text.runs {
                XCTAssertLessThanOrEqual(run.range.upperBound, text.utf16Length)
            }
        }
    }

    func testEveryPositionRoundTripsThroughDisplayOffsets() throws {
        let book = try Fixtures.sampleBook()
        for chapter in book.chapters {
            let text = ChapterText(chapter: chapter)
            for block in chapter.blocks where block.hasText {
                for offset in 0...block.length {
                    let position = BlockPosition(block: block.ordinal, offset: offset)
                    let utf16 = try XCTUnwrap(text.utf16Offset(of: position))
                    XCTAssertEqual(text.position(atUTF16: utf16, forward: true), position)
                }
            }
        }
    }

    func testSelectionAcrossParagraphsAndEmptyLine() throws {
        let book = try Fixtures.sampleBook()
        let chapter = book.chapters[1]
        let text = ChapterText(chapter: chapter)
        let start = try XCTUnwrap(utf16Offset(of: "Ефим", in: text.string))
        let end = try XCTUnwrap(utf16Offset(of: "Соль", in: text.string)) + 4
        let range = try XCTUnwrap(text.blockRange(forUTF16: start..<end))
        XCTAssertEqual(range.start, BlockPosition(block: 7, offset: 15))
        XCTAssertEqual(range.end, BlockPosition(block: 9, offset: 6))
        XCTAssertEqual(book.text(in: range), "Ефим снял шапку и долго смотрел на огни.[1]\n— Соль")
    }

    func testSelectionEdgesOnParagraphBreaksMoveOntoText() throws {
        let book = try Fixtures.sampleBook()
        let text = ChapterText(chapter: book.chapters[2])
        let first = try XCTUnwrap(text.segment(forBlock: 19))
        let second = try XCTUnwrap(text.segment(forBlock: 20))
        // From the end of block 19 (its "\n") to the very start of block 21.
        let third = try XCTUnwrap(text.segment(forBlock: 21))
        let range = try XCTUnwrap(text.blockRange(forUTF16: first.range.upperBound..<third.range.lowerBound))
        XCTAssertEqual(range.start, BlockPosition(block: 20, offset: 0))
        XCTAssertEqual(range.end, BlockPosition(block: 20, offset: second.block.length))
        XCTAssertEqual(book.text(in: range), "Один мешок оказался легче остальных.")
    }

    func testSelectionWithoutTextIsRejected() throws {
        let book = try Fixtures.sampleBook()
        let text = ChapterText(chapter: book.chapters[1])
        let emptyLine = try XCTUnwrap(text.segment(forBlock: 8))
        XCTAssertEqual(emptyLine.range.count, 0)
        // Only the two line breaks around the empty line.
        XCTAssertNil(text.blockRange(forUTF16: (emptyLine.range.lowerBound - 1)..<(emptyLine.range.upperBound + 1)))
    }

    func testAstralCharactersCountOnceInLocatorsTwiceInUTF16() throws {
        let book = try parse(fb2(body: "<section><p>А𝔄Б🧂В</p></section>"))
        let block = try XCTUnwrap(book.allBlocks.first)
        XCTAssertEqual(block.length, 5)
        XCTAssertEqual(block.text.utf16.count, 7)
        let text = ChapterText(chapter: book.chapters[0])
        XCTAssertEqual(text.utf16Offset(of: BlockPosition(block: 0, offset: 2)), 3)
        XCTAssertEqual(text.utf16Offset(of: BlockPosition(block: 0, offset: 4)), 6)
        // A UTF-16 offset inside a surrogate pair rounds down to the scalar's start.
        XCTAssertEqual(text.position(atUTF16: 2, forward: true), BlockPosition(block: 0, offset: 1))
        let range = try XCTUnwrap(text.blockRange(forUTF16: 1..<6))
        XCTAssertEqual(book.text(in: range), "𝔄Б🧂")
    }

    func testImageBlockIsAnAttachmentCharacter() throws {
        let book = try parse(fb2(body: ##"<section><p>До</p><image l:href="#i"/><p>После</p></section>"##))
        let text = ChapterText(chapter: book.chapters[0])
        XCTAssertEqual(text.string, "До\n\u{FFFC}\nПосле")
        // Offsets on the image snap to the following text.
        XCTAssertEqual(text.position(atUTF16: 3, forward: true), BlockPosition(block: 2, offset: 0))
        XCTAssertEqual(text.position(atUTF16: 3, forward: false), BlockPosition(block: 0, offset: 2))
    }

    func testRangeSpanningChaptersIsClippedPerChapter() throws {
        let book = try Fixtures.sampleBook()
        let range = BlockRange(start: BlockPosition(block: 14, offset: 3), end: BlockPosition(block: 17, offset: 5))
        let first = ChapterText(chapter: book.chapters[1])
        let second = ChapterText(chapter: book.chapters[2])
        let firstRange = try XCTUnwrap(first.utf16Range(of: range))
        XCTAssertEqual(firstRange.upperBound, first.utf16Length)
        let secondRange = try XCTUnwrap(second.utf16Range(of: range))
        XCTAssertEqual(secondRange.lowerBound, 0)
        XCTAssertNil(ChapterText(chapter: book.chapters[3]).utf16Range(of: range))
    }
}

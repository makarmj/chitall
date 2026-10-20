import Foundation
import XCTest
@testable import ChitallCore

/// Iteration 5 "Чтение и слова": paragraph steps, the pause timer, dictionary terms, dictation.
final class ReadingWordsTests: XCTestCase {
    // MARK: Paragraph steps

    private func steps(_ body: String) throws -> (ChapterText, ParagraphSteps, [String]) {
        let book = try parse(fb2(body: body))
        let text = ChapterText(chapter: book.chapters[0])
        let steps = ParagraphSteps(text)
        let utf16 = Array(text.string.utf16)
        let strings = steps.ranges.map { String(decoding: utf16[$0], as: UTF16.self) }
        return (text, steps, strings)
    }

    func testHeadingComesWithItsParagraphAndLongParagraphsStandAlone() throws {
        let long1 = String(repeating: "Обоз шёл медленно по мокрой дороге. ", count: 3)
        let long2 = String(repeating: "Стражник смотрел на мешки и молчал. ", count: 3)
        let (_, steps, strings) = try steps("<section><title><p>Глава первая</p></title><p>\(long1)</p><p>\(long2)</p></section>")
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(strings[0], "Глава первая\n" + long1.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(strings[1], long2.trimmingCharacters(in: .whitespaces))
    }

    func testShortLinesShareAScreenAndSignaturesStayWithTheirText() throws {
        let body = """
            <section>
            <epigraph><p>Всякий товар досматривается.</p><p>И соль тоже.</p><text-author>Уставная грамота</text-author></epigraph>
            <p>— Чья соль?</p><p>— Наша.</p><p>— Печать есть?</p>
            <p>\(String(repeating: "Писарь долго смотрел на печать, потом на возчиков. ", count: 2))</p>
            </section>
            """
        let (_, steps, strings) = try steps(body)
        XCTAssertEqual(strings, [
            "Всякий товар досматривается.\nИ соль тоже.\nУставная грамота",
            "— Чья соль?\n— Наша.\n— Печать есть?",
            String(repeating: "Писарь долго смотрел на печать, потом на возчиков. ", count: 2).trimmingCharacters(in: .whitespaces),
        ])
        XCTAssertEqual(steps.count, 3)
    }

    func testStanzasAreStepsOfTheirOwn() throws {
        let body = """
            <section><poem><title><p>Песня</p></title>
            <stanza><v>Снег по колено,</v><v>соль по плечо.</v></stanza>
            <stanza><v>Рогожа намокнет,</v><v>мешок отсыреет.</v></stanza>
            <text-author>Возчики</text-author></poem></section>
            """
        let (_, _, strings) = try steps(body)
        XCTAssertEqual(strings, [
            "Песня\nСнег по колено,\nсоль по плечо.",
            "Рогожа намокнет,\nмешок отсыреет.\nВозчики",
        ])
    }

    func testStepsCoverWholeBlocksAndFindEveryOffset() throws {
        let book = try Fixtures.sampleBook()
        for chapter in book.chapters {
            let text = ChapterText(chapter: chapter)
            let steps = ParagraphSteps(text)
            XCTAssertGreaterThan(steps.count, 0, chapter.title)
            var previousEnd = -1
            for (index, range) in steps.ranges.enumerated() {
                XCTAssertGreaterThan(range.lowerBound, previousEnd, "ascending, not overlapping")
                previousEnd = range.upperBound
                // A step starts and ends on block boundaries: highlights and locators keep working.
                XCTAssertTrue(text.segments.contains { $0.range.lowerBound == range.lowerBound })
                XCTAssertTrue(text.segments.contains { $0.range.upperBound == range.upperBound })
                XCTAssertEqual(steps.index(containing: range.lowerBound), index)
                XCTAssertEqual(steps.index(containing: range.upperBound - 1), index)
            }
            XCTAssertEqual(steps.index(containing: -5), 0)
            XCTAssertEqual(steps.index(containing: text.utf16Length + 5), steps.count - 1)
        }
    }

    // MARK: Pause timer

    func testPauseTimerCountsDownAndTurnsOff() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var timer = PauseTimer()
        XCTAssertFalse(timer.isOn)
        XCTAssertNil(timer.shortLabel(at: start))
        XCTAssertEqual(timer.statusLabel(at: start), "Напоминание о паузе выключено")

        timer.start(minutes: 15, at: start)
        XCTAssertTrue(timer.isOn)
        XCTAssertEqual(timer.minutes, 15)
        XCTAssertEqual(timer.shortLabel(at: start), "15 мин")
        XCTAssertEqual(timer.shortLabel(at: start + 5 * 60 + 10), "10 мин", "rounded up")
        XCTAssertEqual(timer.shortLabel(at: start + 15 * 60 - 1), "1 мин", "never 0 мин before the end")
        XCTAssertFalse(timer.isDue(at: start + 15 * 60 - 1))
        XCTAssertTrue(timer.isDue(at: start + 15 * 60))
        XCTAssertEqual(timer.shortLabel(at: start + 20 * 60), "пора")
        XCTAssertEqual(timer.statusLabel(at: start + 60), "Пауза через 14 мин")

        timer.start(minutes: 0, at: start)
        XCTAssertFalse(timer.isOn)
        XCTAssertEqual(timer.minutes, 0)
        XCTAssertEqual(PauseTimer.choices, [10, 15, 20, 30])
    }

    // MARK: Dictionary term

    func testLookupTermDropsWhatBooksAddAroundWords() {
        XCTAssertEqual(LookupTerm.make(from: "«пищаль,»"), "пищаль")
        XCTAssertEqual(LookupTerm.make(from: "приво\u{0301}лье"), "приволье", "stress marks go")
        XCTAssertEqual(LookupTerm.make(from: "засе\u{00AD}ка"), "засека", "soft hyphens go")
        XCTAssertEqual(LookupTerm.make(from: "печатью.[2]"), "печатью", "footnote numbers go")
        XCTAssertEqual(LookupTerm.make(from: "  — из-за  "), "из-за")
        XCTAssertEqual(LookupTerm.make(from: "Гостиный\nдвор"), "Гостиный двор")
        XCTAssertNil(LookupTerm.make(from: "Утром пришёл писарь с печатью и пересчитал мешки"), "a sentence is not a term")
        XCTAssertNil(LookupTerm.make(from: " … — "))
        XCTAssertNil(LookupTerm.make(from: "1612"))
    }

    // MARK: Dictation

    func testDictationIsAppendedAsItsOwnSentence() {
        XCTAssertEqual(DictationText.merge("", "это важно для сцены"), "Это важно для сцены")
        XCTAssertEqual(DictationText.merge("Туман как занавес", "это важно"), "Туман как занавес. Это важно")
        XCTAssertEqual(DictationText.merge("Туман как занавес.  ", "это важно"), "Туман как занавес. Это важно")
        XCTAssertEqual(DictationText.merge("Туман,", "как занавес"), "Туман, как занавес")
        XCTAssertEqual(DictationText.merge("Сцена:\n", "ночь у ворот"), "Сцена:\nНочь у ворот")
        XCTAssertEqual(DictationText.merge("Мысль", "   "), "Мысль")
        // The transcript grows while the reader speaks: merged with the same start, never doubled.
        let start = "Ефим молчит"
        var note = start
        for partial in ["потому", "потому что", "потому что боится"] {
            note = DictationText.merge(start, partial)
        }
        XCTAssertEqual(note, "Ефим молчит. Потому что боится")
    }
}

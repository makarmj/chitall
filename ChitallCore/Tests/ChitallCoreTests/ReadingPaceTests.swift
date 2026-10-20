import Foundation
import XCTest
@testable import ChitallCore

final class ReadingPaceTests: XCTestCase {
    func testWordIndexCountsWordsInUTF16Offsets() {
        let index = WordIndex("Утром пришёл писарь,[2] кое-как 12 мешков.\n«Ёж» 😀 ушёл")
        // Утром, пришёл, писарь, 2, кое, как, 12, мешков, Ёж, ушёл
        XCTAssertEqual(index.count, 10)
        XCTAssertEqual(index.starts.first, 0)
        XCTAssertEqual(index.words(from: 0), 10)
        XCTAssertEqual(index.words(from: 6), 9) // from "пришёл"
        XCTAssertEqual(index.words(in: 0..<6), 1)
        // The emoji takes two UTF-16 units: "ушёл" starts right after it and a space.
        let string = "Утром пришёл писарь,[2] кое-как 12 мешков.\n«Ёж» 😀 ушёл" as NSString
        XCTAssertEqual(index.starts.last, string.range(of: "ушёл").location)
        XCTAssertEqual(index.words(from: 10_000), 0)
        XCTAssertEqual(WordIndex("").words(from: 0), 0)
    }

    func testPaceStartsAtDefaultAndLearnsFromPlausibleReading() {
        var pace = ReadingPace()
        XCTAssertEqual(pace.effectiveWordsPerMinute, 150)
        XCTAssertEqual(pace.minutes(forWords: 900), 6)
        XCTAssertEqual(pace.minutes(forWords: 10), 1)
        XCTAssertEqual(pace.minutes(forWords: 0), 0)

        // A page of 200 words in a minute: 200 wpm, but only partly trusted at first.
        XCTAssertTrue(pace.record(words: 200, seconds: 60))
        XCTAssertEqual(pace.wordsPerMinute, 200, accuracy: 0.001)
        XCTAssertGreaterThan(pace.effectiveWordsPerMinute, 150)
        XCTAssertLessThan(pace.effectiveWordsPerMinute, 200)

        XCTAssertTrue(pace.record(words: 200, seconds: 60))
        XCTAssertEqual(pace.effectiveWordsPerMinute, 200, accuracy: 0.001)
        XCTAssertEqual(pace.minutes(forWords: 1000), 5)
    }

    func testPaceIgnoresJumpsPausesAndTinyStretches() {
        var pace = ReadingPace()
        XCTAssertFalse(pace.record(words: 3000, seconds: 2)) // the slider
        XCTAssertFalse(pace.record(words: 2000, seconds: 30)) // skimming / a jump
        XCTAssertFalse(pace.record(words: 150, seconds: 1800)) // put the phone down
        XCTAssertFalse(pace.record(words: 5, seconds: 4)) // too little to tell
        XCTAssertEqual(pace, ReadingPace())
    }

    func testPaceFollowsRecentReadingSlowly() {
        var pace = ReadingPace()
        for _ in 0..<20 { pace.record(words: 200, seconds: 60) } // 4000 words at 200 wpm
        pace.record(words: 100, seconds: 60) // one slow page
        XCTAssertGreaterThan(pace.wordsPerMinute, 190)
        XCTAssertLessThan(pace.wordsPerMinute, 200)
    }

    func testPaceRoundTripsThroughJSON() throws {
        var pace = ReadingPace()
        pace.record(words: 240, seconds: 90)
        let data = try JSONEncoder().encode(pace)
        XCTAssertEqual(try JSONDecoder().decode(ReadingPace.self, from: data), pace)
    }

    func testChapterLeftLabel() {
        let pace = ReadingPace()
        XCTAssertEqual(pace.chapterLeftLabel(words: 900), "≈ 6 мин до конца главы")
        XCTAssertNil(pace.chapterLeftLabel(words: 0))
    }

    func testResumeSnippetKeepsShortTextWhole() {
        XCTAssertEqual(ResumeSnippet.make(from: "Ефим\nпромолчал.  "), "Ефим промолчал.")
        XCTAssertNil(ResumeSnippet.make(from: " \n "))
    }

    func testResumeSnippetStartsAtASentenceOrMarksTheCut() {
        let text = "Утром пришёл писарь с печатью. Он пересчитал мешки дважды. Один мешок оказался легче остальных."
        XCTAssertEqual(ResumeSnippet.make(from: text, limit: 70), "Один мешок оказался легче остальных.")
        let noSentence = "один два три четыре пять шесть семь восемь девять десять"
        XCTAssertEqual(ResumeSnippet.make(from: noSentence, limit: 20), "…восемь девять десять")
        // A closing quote after the full stop still ends the sentence.
        let quoted = "Он сказал: «Довольно.» Мешки унесли на склад у ворот"
        XCTAssertEqual(ResumeSnippet.make(from: quoted, limit: 45), "Мешки унесли на склад у ворот")
    }
}

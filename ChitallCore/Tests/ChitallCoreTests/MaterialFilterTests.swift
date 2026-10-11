import Foundation
import XCTest
@testable import ChitallCore

final class MaterialFilterTests: XCTestCase {
    private func matches(_ filter: MaterialFilter, text: String = "Один мешок оказался легче остальных.", note: String = "Кто-то отсыпал соль?", tags: [String] = ["тайна", "предмет"], color: HighlightColor = .cinnabar, book: String = "sha256:a") -> Bool {
        filter.matches(text: text, note: note, tags: tags, color: color, bookFingerprint: book, bookTitle: "Соляной обоз", chapterTitle: "Глава вторая")
    }

    func testEmptyFilterMatchesEverything() {
        XCTAssertFalse(MaterialFilter().isActive)
        XCTAssertTrue(matches(MaterialFilter()))
        XCTAssertFalse(MaterialFilter(query: "   ").isActive)
    }

    func testSearchIsCaseInsensitiveAndFoldsYo() {
        XCTAssertTrue(matches(MaterialFilter(query: "МЕШОК")))
        XCTAssertTrue(matches(MaterialFilter(query: "мешок соль"))) // words from quote and thought
        XCTAssertTrue(matches(MaterialFilter(query: "соляной")))   // book title
        XCTAssertTrue(matches(MaterialFilter(query: "ещё"), text: "ещё раз"))
        XCTAssertTrue(matches(MaterialFilter(query: "еще"), text: "ещё раз"))
        XCTAssertFalse(matches(MaterialFilter(query: "мешок собака")))
    }

    func testHashWordsFilterByTag() {
        XCTAssertTrue(matches(MaterialFilter(query: "#тайна")))
        XCTAssertTrue(matches(MaterialFilter(query: "#Тайна мешок")))
        XCTAssertFalse(matches(MaterialFilter(query: "#кадр")))
        // "#тай" is not the tag "тайна".
        XCTAssertFalse(matches(MaterialFilter(query: "#тай")))
    }

    func testBookTagAndColorFilters() {
        XCTAssertTrue(matches(MaterialFilter(bookFingerprint: "sha256:a")))
        XCTAssertFalse(matches(MaterialFilter(bookFingerprint: "sha256:b")))
        XCTAssertTrue(matches(MaterialFilter(tag: "предмет")))
        XCTAssertFalse(matches(MaterialFilter(tag: "свет")))
        XCTAssertTrue(matches(MaterialFilter(color: .cinnabar)))
        XCTAssertFalse(matches(MaterialFilter(color: .olive)))
    }

    func testSummary() {
        XCTAssertEqual(MaterialFilter().summary(bookTitle: nil), "все материалы")
        XCTAssertEqual(
            MaterialFilter(query: " соль ", bookFingerprint: "sha256:a", tag: "тайна", color: .ochre).summary(bookTitle: "Соляной обоз"),
            "книга «Соляной обоз», тег #тайна, цвет охра, поиск «соль»"
        )
    }

    func testRussianPlural() {
        XCTAssertEqual([0, 1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 101, 111].map(RussianPlural.highlights), [
            "0 выделений", "1 выделение", "2 выделения", "4 выделения", "5 выделений", "11 выделений",
            "12 выделений", "14 выделений", "21 выделение", "22 выделения", "25 выделений", "101 выделение", "111 выделений",
        ])
        XCTAssertEqual(RussianPlural.books(3), "3 книги")
    }
}

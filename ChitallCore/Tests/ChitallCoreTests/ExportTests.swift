import Foundation
import XCTest
@testable import ChitallCore

final class ExportTests: XCTestCase {
    private let moscow = TimeZone(secondsFromGMT: 3 * 3600)!

    private func sampleItems() throws -> [MaterialItem] {
        let data = try Fixtures.data("sample-utf8.fb2")
        let book = try parse(data)
        let service = LocatorService(book: book, fingerprint: Fingerprint.of(data))
        let first = try XCTUnwrap(service.locator(for: BlockRange(
            start: BlockPosition(block: 7, offset: 15),
            end: BlockPosition(block: 9, offset: 6)
        )))
        let second = try XCTUnwrap(service.locator(for: BlockRange(
            start: BlockPosition(block: 20, offset: 0),
            end: BlockPosition(block: 20, offset: 36)
        )))
        let created = Date(timeIntervalSince1970: 1_791_720_000) // 2026-10-11 12:00 UTC
        return [
            // Deliberately out of reading order: export sorts by position.
            MaterialItem(
                id: "B0000000-0000-0000-0000-000000000002",
                bookFingerprint: first.book,
                bookTitle: "Соляной обоз",
                bookAuthors: "Анна Тестова",
                chapterIndex: 2,
                chapterTitle: "Глава вторая",
                text: "Один мешок оказался легче остальных.",
                note: "Кто-то отсыпал соль по дороге?\nПроверить, кто ночью стоял у возов.",
                tags: ["тайна", "предмет"],
                color: .cinnabar,
                createdAt: created.addingTimeInterval(600),
                updatedAt: created.addingTimeInterval(1800),
                locator: second
            ),
            MaterialItem(
                id: "A0000000-0000-0000-0000-000000000001",
                bookFingerprint: first.book,
                bookTitle: "Соляной обоз",
                bookAuthors: "Анна Тестова",
                chapterIndex: 1,
                chapterTitle: "Глава первая. Застава",
                text: first.quote!.exact,
                note: "",
                tags: ["кадр"],
                color: .ochre,
                createdAt: created,
                updatedAt: created,
                locator: first
            ),
        ]
    }

    func testMarkdownGolden() throws {
        let items = try sampleItems()
        let export = MaterialExport(
            items: items,
            exportedAt: Date(timeIntervalSince1970: 1_791_727_200), // 2026-10-11 14:00 UTC
            selectionDescription: "все материалы",
            timeZone: moscow
        )
        let short = Fingerprint.short(items[0].bookFingerprint)
        let expected = """
            # Материалы Chitall

            - Экспорт: 2026-10-11 17:00 (\(moscow.identifier))
            - Выборка: все материалы
            - Выделений: 2, книг: 1

            ---

            ## Соляной обоз

            *Анна Тестова*

            ### Глава первая. Застава

            > Ефим снял шапку и долго смотрел на огни.[1]
            >
            > — Соль

            - Теги: #кадр
            - Цвет: охра
            - Создано: 2026-10-11 15:00
            - Место: `fb2 \(short) /FictionBook/body[1]/section[1]/p[2]:15–/FictionBook/body[1]/section[1]/p[3]:6`, \(MaterialExport.percent(items[1].locator.progression)) книги

            ### Глава вторая

            > Один мешок оказался легче остальных.

            **Мысль.** Кто-то отсыпал соль по дороге?\("  ")
            Проверить, кто ночью стоял у возов.

            - Теги: #тайна #предмет
            - Цвет: киноварь
            - Создано: 2026-10-11 15:10
            - Изменено: 2026-10-11 15:30
            - Место: `fb2 \(short) /FictionBook/body[1]/section[2]/p[2]:0–36`, \(MaterialExport.percent(items[0].locator.progression)) книги

            """
        XCTAssertEqual(MarkdownExporter.render(export), expected)
    }

    func testJSONStructure() throws {
        let items = try sampleItems()
        let export = MaterialExport(
            items: items,
            exportedAt: Date(timeIntervalSince1970: 1_791_727_200),
            selectionDescription: "тег #кадр",
            generator: "Chitall 0.1 (1)",
            timeZone: moscow
        )
        let data = try JSONExporter.render(export)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["schema"] as? String, "chitall.export")
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["generator"] as? String, "Chitall 0.1 (1)")
        XCTAssertEqual(root["exportedAt"] as? String, "2026-10-11T14:00:00Z")

        let selection = try XCTUnwrap(root["selection"] as? [String: Any])
        XCTAssertEqual(selection["description"] as? String, "тег #кадр")
        XCTAssertEqual(selection["highlightCount"] as? Int, 2)
        XCTAssertEqual(selection["bookCount"] as? Int, 1)

        let books = try XCTUnwrap(root["books"] as? [[String: Any]])
        XCTAssertEqual(books.first?["title"] as? String, "Соляной обоз")
        XCTAssertEqual(books.first?["id"] as? String, items[0].bookFingerprint)

        let highlights = try XCTUnwrap(root["highlights"] as? [[String: Any]])
        XCTAssertEqual(highlights.map { $0["id"] as? String }, [items[1].id, items[0].id], "reading order")
        let first = highlights[0]
        XCTAssertEqual(first["text"] as? String, "Ефим снял шапку и долго смотрел на огни.[1]\n— Соль")
        XCTAssertEqual(first["tags"] as? [String], ["кадр"])
        XCTAssertEqual((first["color"] as? [String: String])?["key"], "ochre")
        XCTAssertEqual((first["color"] as? [String: String])?["name"], "охра")
        XCTAssertEqual((first["chapter"] as? [String: Any])?["title"] as? String, "Глава первая. Застава")
        XCTAssertEqual(first["createdAt"] as? String, "2026-10-11T12:00:00Z")

        let locator = try XCTUnwrap(first["locator"] as? [String: Any])
        XCTAssertEqual(locator["v"] as? Int, 1)
        XCTAssertEqual(locator["format"] as? String, "fb2")
        XCTAssertEqual((locator["start"] as? [String: Any])?["path"] as? String, "/FictionBook/body[1]/section[1]/p[2]")
        XCTAssertEqual((locator["end"] as? [String: Any])?["offset"] as? Int, 6)
        XCTAssertNil(locator["quote"], "context of the quote is book text and must not be exported")

        // The decoded locator is the stored one minus the quote.
        let decoded = try JSONDecoder().decode(Locator.self, from: JSONSerialization.data(withJSONObject: locator))
        XCTAssertEqual(decoded, items[1].locator.withoutQuote)
    }

    func testExportContainsOnlySelectedMaterial() throws {
        let items = try sampleItems()
        let export = MaterialExport(items: items, exportedAt: Date(), selectionDescription: "все", timeZone: moscow)
        let markdown = MarkdownExporter.render(export)
        let json = String(decoding: try JSONExporter.render(export), as: UTF8.self)
        for item in items {
            let quote = try XCTUnwrap(item.locator.quote)
            for context in [quote.prefix, quote.suffix] where !context.isEmpty {
                XCTAssertFalse(markdown.contains(context), "Markdown leaks book context: \(context)")
                XCTAssertFalse(json.contains(context), "JSON leaks book context: \(context)")
            }
        }
        // Text of the book that nobody selected stays out.
        XCTAssertFalse(markdown.contains("Ночью лаяли собаки"))
        XCTAssertFalse(json.contains("Ночью лаяли собаки"))
    }

    func testEmptyExport() throws {
        let export = MaterialExport(items: [], exportedAt: Date(timeIntervalSince1970: 0), selectionDescription: "тег #свет", timeZone: moscow)
        XCTAssertTrue(MarkdownExporter.render(export).contains("Нет материалов для экспорта."))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONExporter.render(export)) as? [String: Any])
        XCTAssertEqual((root["highlights"] as? [Any])?.count, 0)
    }

    func testMarkdownEscapesLineStarts() {
        XCTAssertEqual(MarkdownExporter.escapeLineStart("# не заголовок"), "\\# не заголовок")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("- не список"), "\\- не список")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("1612. Год"), "1612\\. Год")
        XCTAssertEqual(MarkdownExporter.escapeLineStart("Обычная строка"), "Обычная строка")
    }

    func testFileStemAndPercent() {
        let export = MaterialExport(items: [], exportedAt: Date(timeIntervalSince1970: 1_791_727_200), selectionDescription: "", timeZone: moscow)
        XCTAssertEqual(export.fileStem, "chitall-materials-20261011-1700")
        XCTAssertEqual(MaterialExport.percent(0.4312), "43,1 %")
        XCTAssertEqual(MaterialExport.percent(1), "100,0 %")
    }

    func testWholePercentForTheReader() {
        XCTAssertEqual(MaterialExport.wholePercent(0.365), "36 %")
        XCTAssertEqual(MaterialExport.wholePercent(0), "0 %")
        XCTAssertEqual(MaterialExport.wholePercent(0.07), "7 %")
        XCTAssertEqual(MaterialExport.wholePercent(0.999), "99 %", "a page before the end is not 100 %")
        XCTAssertEqual(MaterialExport.wholePercent(0.97, atEnd: true), "100 %")
        XCTAssertEqual(MaterialExport.wholePercent(1), "100 %")
    }

    func testBooksAreGroupedAndSortedByTitle() throws {
        var items = try sampleItems()
        items[0].bookFingerprint = "sha256:other"
        items[0].bookTitle = "Атлас дорог"
        let groups = MaterialExport(items: items, exportedAt: Date(), selectionDescription: "").groupedByBook
        XCTAssertEqual(groups.map(\.title), ["Атлас дорог", "Соляной обоз"])
    }
}

final class TagNamesTests: XCTestCase {
    func testNormalization() {
        XCTAssertEqual(TagNames.normalize("#Тайна"), "тайна")
        XCTAssertEqual(TagNames.normalize("  ##ТАЙНА  "), "тайна")
        XCTAssertEqual(TagNames.normalize("старый   город"), "старый_город")
        XCTAssertNil(TagNames.normalize("   "))
        XCTAssertNil(TagNames.normalize("#"))
        XCTAssertEqual(TagNames.normalize(String(repeating: "я", count: 60))?.count, TagNames.maximumLength)
    }

    func testParsingUserInput() {
        XCTAssertEqual(TagNames.parseList("#тайна #Кадр, старый город #тайна"), ["тайна", "кадр", "старый_город"])
        XCTAssertEqual(TagNames.parseList(""), [])
    }

    func testDefaultsAreNormalized() {
        XCTAssertEqual(TagNames.normalizeAll(TagNames.defaults), TagNames.defaults)
        XCTAssertEqual(TagNames.defaults.count, 9)
    }

    func testColorsHaveRussianNamesAndSafeFallback() {
        XCTAssertEqual(HighlightColor.allCases.map(\.displayName), ["охра", "олива", "лазурь", "киноварь", "сирень"])
        XCTAssertEqual(HighlightColor(storedValue: "ultraviolet"), .ochre)
    }
}

import SwiftData
import UIKit
import XCTest
@testable import Chitall

/// App-level tests: SwiftData persistence, import into the library, rendering invariants and
/// the reader's highlight round trip. Core logic (FB2, locators, export) is covered by
/// ChitallCoreTests. These tests need Xcode and an iOS simulator.
@MainActor
final class AppTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private func makeFiles() throws -> BookFileStore {
        let files = BookFileStore(root: temporaryRoot.appendingPathComponent("Library", isDirectory: true))
        try files.prepare()
        return files
    }

    private func sampleData() throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "chitall-sample", withExtension: "fb2"), "sample book is bundled")
        return try Data(contentsOf: url)
    }

    // MARK: Persistence

    func testHighlightSurvivesContainerRestart() throws {
        let storeURL = temporaryRoot.appendingPathComponent("store.sqlite")
        let id = UUID()
        do {
            let container = try ChitallStore.makeContainer(storeURL: storeURL)
            let context = ModelContext(container)
            let highlight = Highlight(
                id: id,
                bookFingerprint: "sha256:abc",
                bookTitle: "Соляной обоз",
                bookAuthors: "Chitall Пример",
                chapterIndex: 1,
                chapterTitle: "Глава первая. Застава",
                text: "белый туман",
                colorKey: HighlightColor.olive.rawValue,
                locatorJSON: #"{"book":"sha256:abc","chapter":1,"format":"fb2","progression":0.1,"start":{"offset":3,"path":"/FictionBook/body[1]/section[1]/p[1]"},"v":1}"#,
                progression: 0.1
            )
            highlight.note = "Туман как занавес."
            highlight.tags = ["свет", "кадр"]
            context.insert(highlight)
            try context.save()
        }
        // A new container on the same file is what the app sees after a relaunch.
        let reopened = try ChitallStore.makeContainer(storeURL: storeURL)
        let stored = try ModelContext(reopened).fetch(FetchDescriptor<Highlight>())
        XCTAssertEqual(stored.count, 1)
        let highlight = try XCTUnwrap(stored.first)
        XCTAssertEqual(highlight.id, id)
        XCTAssertEqual(highlight.note, "Туман как занавес.")
        XCTAssertEqual(highlight.tags, ["свет", "кадр"])
        XCTAssertEqual(highlight.color, .olive)
        XCTAssertEqual(highlight.locator?.start.path, "/FictionBook/body[1]/section[1]/p[1]")
    }

    // MARK: Import and library

    func testImportSampleThenDuplicateThenDeleteKeepingMaterials() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let files = try makeFiles()
        let importer = BookImportService(files: files)
        let data = try sampleData()

        guard case let .imported(book) = try await importer.importData(data, originalFileName: "sample.fb2", into: context) else {
            return XCTFail("expected a new book")
        }
        XCTAssertEqual(book.title, "Соляной обоз")
        XCTAssertEqual(book.fingerprint, Fingerprint.of(data))
        XCTAssertTrue(files.bookExists(named: book.fileName))
        XCTAssertEqual(try files.readBook(named: book.fileName), data, "the exact source bytes are kept")

        guard case .alreadyInLibrary = try await importer.importData(data, originalFileName: "copy.fb2", into: context) else {
            return XCTFail("expected duplicate detection by fingerprint")
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredBook>()), 1)

        let highlight = Highlight(
            bookFingerprint: book.fingerprint, bookTitle: book.title, bookAuthors: book.authors,
            chapterIndex: 1, chapterTitle: "Глава первая. Застава", text: "Обоз",
            colorKey: HighlightColor.ochre.rawValue, locatorJSON: "{}", progression: 0
        )
        context.insert(highlight)
        try context.save()
        XCTAssertEqual(LibraryActions.highlightCount(for: book.fingerprint, in: context), 1)

        let fileName = book.fileName
        try LibraryActions.delete(book, keepMaterials: true, context: context, files: files)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StoredBook>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Highlight>()), 1, "materials kept")
        XCTAssertFalse(files.bookExists(named: fileName))
    }

    func testDeleteBookTogetherWithMaterials() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: context) else {
            return XCTFail("expected a new book")
        }
        context.insert(Highlight(
            bookFingerprint: book.fingerprint, bookTitle: book.title, bookAuthors: "", chapterIndex: 0,
            chapterTitle: "", text: "x", colorKey: "ochre", locatorJSON: "{}", progression: 0
        ))
        try context.save()
        try LibraryActions.delete(book, keepMaterials: false, context: context, files: files)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Highlight>()), 0)
    }

    func testBrokenFileGivesClearMessage() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let importer = BookImportService(files: try makeFiles())
        do {
            _ = try await importer.importData(Data("<html><body>не книга</body></html>".utf8), originalFileName: "x.fb2", into: container.mainContext)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(BookImportService.message(for: error), "Это не книга FB2: корневой элемент «html» вместо «FictionBook».")
        }
    }

    func testTagCatalogSeedsDefaultsOnce() throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "chitall.tests.\(UUID().uuidString)"))
        TagCatalog.seedIfNeeded(context, defaults: defaults)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TagRecord>()).map(\.name).sorted(), TagNames.defaults.sorted())
        TagCatalog.ensure("рынок", in: context)
        TagCatalog.ensure("рынок", in: context)
        TagCatalog.seedIfNeeded(context, defaults: defaults)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TagRecord>()), TagNames.defaults.count + 1)
    }

    // MARK: Rendering

    func testRenderingKeepsTheCharacterMapExact() throws {
        let book = try FB2Parser.parse(sampleData()).book
        let style = ReaderStyle(fontSize: 19, lineSpacing: 1.35)
        for chapter in book.chapters {
            let text = ChapterText(chapter: chapter)
            let rendered = ChapterRenderer.render(text, book: book, style: style)
            XCTAssertEqual(rendered.length, text.utf16Length, chapter.title)
            XCTAssertEqual(rendered.string, text.string, chapter.title)
        }
    }

    func testFootnoteReferencesBecomeInternalLinks() throws {
        let book = try FB2Parser.parse(sampleData()).book
        let text = ChapterText(chapter: book.chapters[1])
        let rendered = ChapterRenderer.render(text, book: book, style: ReaderStyle(fontSize: 19, lineSpacing: 1.35))
        var links: [URL] = []
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links.map(\.scheme), ["chitall-note"])
        XCTAssertEqual(links.first.flatMap(ChapterRenderer.linkTarget), "n1")
    }

    // MARK: Reader round trip

    func testReaderCreatesHighlightAndRestoresReadingPosition() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: context) else {
            return XCTFail("expected a new book")
        }

        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.35), initialHighlight: nil)
        XCTAssertEqual(model.phase, .ready)
        model.show(chapter: 1)
        let rendered = try XCTUnwrap(model.rendered)
        let start = (rendered.text.string as NSString).range(of: "белый")
        let highlight = try XCTUnwrap(model.createHighlight(for: start, color: .azure, context: context))
        XCTAssertEqual(highlight.text, "белый")
        XCTAssertEqual(highlight.chapterTitle, "Глава первая. Застава")
        XCTAssertEqual(highlight.locator?.start.path, "/FictionBook/body[1]/section[1]/p[1]")
        XCTAssertEqual(model.decorations(for: [highlight]).first?.range, start)

        let paragraph = (rendered.text.string as NSString).range(of: "Стражник был молод")
        model.saveReadingPosition(atUTF16: paragraph.location)
        XCTAssertNotNil(book.readingPositionJSON)

        let reopened = ReaderModel(book: book, files: files)
        await reopened.load(style: ReaderStyle(fontSize: 22, lineSpacing: 1.5), initialHighlight: nil)
        XCTAssertEqual(reopened.chapterIndex, 1)
        XCTAssertEqual(reopened.scrollRequest?.utf16Offset, paragraph.location)
    }
}

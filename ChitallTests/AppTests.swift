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
        let selection = ChapterRange(chapter: 1, range: start)
        let highlight = try XCTUnwrap(model.createHighlight(for: selection, color: .azure, context: context))
        XCTAssertEqual(highlight.text, "белый")
        XCTAssertEqual(highlight.chapterTitle, "Глава первая. Застава")
        XCTAssertEqual(highlight.locator?.start.path, "/FictionBook/body[1]/section[1]/p[1]")
        XCTAssertEqual(model.decorations(for: [highlight], chapter: 1).first?.range, start)
        XCTAssertTrue(model.decorations(for: [highlight], chapter: 2).isEmpty)

        let paragraph = (rendered.text.string as NSString).range(of: "Стражник был молод")
        model.saveReadingPosition(chapter: 1, atUTF16: paragraph.location)
        XCTAssertNotNil(book.readingPositionJSON)

        let reopened = ReaderModel(book: book, files: files)
        await reopened.load(style: ReaderStyle(fontSize: 22, lineSpacing: 1.5), initialHighlight: nil)
        XCTAssertEqual(reopened.chapterIndex, 1)
        XCTAssertEqual(reopened.navigation?.chapter, 1)
        XCTAssertEqual(reopened.navigation?.utf16Offset, paragraph.location)
    }

    func testSearchJumpsToChapterAndMarksTheHit() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: container.mainContext) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.35), initialHighlight: nil)
        let found = await model.search("опись")
        let hit = try XCTUnwrap(found?.hits.first)
        model.go(to: hit)
        XCTAssertEqual(model.chapterIndex, hit.chapterIndex)
        XCTAssertEqual(model.navigation?.chapter, hit.chapterIndex)
        XCTAssertEqual(model.navigation?.placement, .upperThird)
        let marks = model.decorations(for: [], chapter: hit.chapterIndex).filter { $0.kind == .searchHit }
        XCTAssertEqual(marks.count, 1)
        let text = try XCTUnwrap(model.rendered(chapter: hit.chapterIndex)).text.string as NSString
        XCTAssertEqual(text.substring(with: try XCTUnwrap(marks.first).range).lowercased(), "опись")
        model.clearSearchHighlight()
        XCTAssertTrue(model.decorations(for: [], chapter: hit.chapterIndex).isEmpty)
    }

    // MARK: Pagination

    private func renderedSampleChapters(fontSize: CGFloat = 19) throws -> [NSAttributedString] {
        let book = try FB2Parser.parse(sampleData()).book
        let style = ReaderStyle(fontSize: fontSize, lineSpacing: 1.35)
        return book.chapters.map { ChapterRenderer.render(ChapterText(chapter: $0), book: book, style: style) }
    }

    func testPagesCoverEveryCharacterExactlyOnce() throws {
        for chapter in try renderedSampleChapters() {
            let pages = Paginator.paginate(chapter, pageSize: CGSize(width: 330, height: 420))
            XCTAssertGreaterThan(pages.count, 0)
            var expected = 0
            for range in pages.ranges {
                XCTAssertEqual(range.location, expected, "pages are contiguous")
                XCTAssertGreaterThan(range.length, 0)
                expected = NSMaxRange(range)
            }
            XCTAssertEqual(expected, chapter.length, "the last page ends at the end of the chapter")
        }
    }

    func testEveryPageFitsItsPage() throws {
        let size = CGSize(width: 330, height: 420)
        for chapter in try renderedSampleChapters() {
            let pages = Paginator.paginate(chapter, pageSize: size)
            for range in pages.ranges {
                // Lay the page out alone, as its page view does, in a container of the page size.
                let content = Paginator.pageContent(of: chapter, range: range)
                let storage = NSTextStorage(attributedString: content)
                let layoutManager = NSLayoutManager()
                storage.addLayoutManager(layoutManager)
                let container = NSTextContainer(size: CGSize(width: size.width, height: size.height + 2))
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)
                let glyphs = layoutManager.glyphRange(for: container)
                XCTAssertEqual(NSMaxRange(glyphs), layoutManager.numberOfGlyphs, "page \(range) overflows")
            }
        }
    }

    func testLargerTypeMeansMorePagesAndOffsetsFindTheirPage() throws {
        let size = CGSize(width: 330, height: 420)
        let small = try renderedSampleChapters(fontSize: 16)[1]
        let large = try renderedSampleChapters(fontSize: 28)[1]
        let smallPages = Paginator.paginate(small, pageSize: size)
        let largePages = Paginator.paginate(large, pageSize: size)
        XCTAssertGreaterThan(largePages.count, smallPages.count)
        for (index, range) in largePages.ranges.enumerated() {
            XCTAssertEqual(largePages.pageIndex(containing: range.location), index)
            XCTAssertEqual(largePages.pageIndex(containing: NSMaxRange(range) - 1), index)
        }
        XCTAssertEqual(largePages.pageIndex(containing: large.length + 10), largePages.count - 1)
    }

    func testPageStartingInsideAParagraphHasNoFirstLineIndent() throws {
        let chapter = try renderedSampleChapters(fontSize: 26)[1]
        let pages = Paginator.paginate(chapter, pageSize: CGSize(width: 300, height: 360))
        let text = chapter.string as NSString
        let continued = try XCTUnwrap(pages.ranges.first { $0.location > 0 && text.character(at: $0.location - 1) != 0x0A })
        let content = Paginator.pageContent(of: chapter, range: continued)
        let style = try XCTUnwrap(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.firstLineHeadIndent, style.headIndent)
        XCTAssertEqual(style.paragraphSpacingBefore, 0)
    }

    func testIllustrationTallerThanPageStillPaginates() throws {
        let text = NSMutableAttributedString(string: "До\n\u{FFFC}\nПосле", attributes: [.font: UIFont.systemFont(ofSize: 18)])
        let attachment = FittingImageAttachment()
        attachment.image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 3000)).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 3000))
        }
        text.addAttribute(.attachment, value: attachment, range: NSRange(location: 3, length: 1))
        let pages = Paginator.paginate(text, pageSize: CGSize(width: 320, height: 400))
        XCTAssertEqual(pages.ranges.reduce(0) { $0 + $1.length }, text.length)
        XCTAssertLessThanOrEqual(attachment.maxHeight, 400)
    }
}

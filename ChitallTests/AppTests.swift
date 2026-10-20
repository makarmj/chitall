import CoreText
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
    /// In-memory stores of the tests' books, alive until the test ends.
    private var retainedContainers: [ModelContainer] = []

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

    func testVersion1StoreMigratesToVersion2KeepingHighlights() throws {
        let storeURL = temporaryRoot.appendingPathComponent("v1.store")
        do {
            // A store exactly as the first app version wrote it.
            let v1 = Schema(versionedSchema: ChitallSchemaV1.self)
            let container = try ModelContainer(for: v1, configurations: ModelConfiguration(schema: v1, url: storeURL, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(ChitallSchemaV1.StoredBook(
                fingerprint: "sha256:old", title: "Старая книга", authors: "Автор",
                fileName: "old.fb2", originalFileName: "old.fb2", fileSize: 10, chapterCount: 1
            ))
            let highlight = ChitallSchemaV1.Highlight(
                bookFingerprint: "sha256:old", bookTitle: "Старая книга", bookAuthors: "Автор",
                chapterIndex: 0, chapterTitle: "Глава", text: "цитата", colorKey: "olive",
                locatorJSON: "{}", progression: 0.5
            )
            highlight.tags = ["тайна"]
            highlight.note = "мысль"
            context.insert(highlight)
            try context.save()
        }

        let migrated = try ChitallStore.makeContainer(storeURL: storeURL)
        let context = ModelContext(migrated)
        let highlights = try context.fetch(FetchDescriptor<Highlight>())
        XCTAssertEqual(highlights.count, 1)
        XCTAssertEqual(highlights.first?.text, "цитата")
        XCTAssertEqual(highlights.first?.note, "мысль")
        XCTAssertEqual(highlights.first?.tags, ["тайна"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<StoredBook>()).first?.title, "Старая книга")
        context.insert(Bookmark(bookFingerprint: "sha256:old", chapterIndex: 0, chapterTitle: "Глава", snippet: "", locatorJSON: "{}", progression: 0))
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bookmark>()), 1)
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

        // On screen the footnote number gets a dotted underline that survives decorations.
        let storage = NSTextStorage(attributedString: rendered)
        DecorationPainter.apply([], to: storage, chapterOffset: 0)
        var underlined: [Int] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            underlined.append(storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0)
        }
        XCTAssertEqual(underlined, [NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue])
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

    func testBookmarkTogglesOnTheVisiblePageAndOpensItsPlace() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: context) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)

        model.didShowPage(chapter: 2, page: 0, pageCount: 3, firstOffset: 0, endOffset: 300)
        model.toggleBookmark(in: [], context: context)
        var bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        XCTAssertEqual(bookmarks.count, 1)
        let bookmark = try XCTUnwrap(bookmarks.first)
        XCTAssertEqual(bookmark.chapterIndex, 2)
        XCTAssertEqual(bookmark.chapterTitle, "Глава вторая. Досмотр")
        XCTAssertFalse(bookmark.snippet.isEmpty)
        XCTAssertTrue(model.bookmarkOnScreen(in: bookmarks) === bookmark)

        model.didShowPage(chapter: 3, page: 0, pageCount: 2, firstOffset: 0, endOffset: 300)
        XCTAssertNil(model.bookmarkOnScreen(in: bookmarks))
        model.go(to: bookmark)
        XCTAssertEqual(model.navigation?.chapter, 2)
        XCTAssertEqual(model.navigation?.utf16Offset, 0)
        XCTAssertEqual(model.bookmarkOffsetsAroundCurrentChapter(bookmarks)[2], [0])

        model.didShowPage(chapter: 2, page: 0, pageCount: 3, firstOffset: 0, endOffset: 300)
        model.toggleBookmark(in: bookmarks, context: context)
        bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        XCTAssertTrue(bookmarks.isEmpty, "a second tap removes the bookmark")
    }

    func testProgressShowsWholePercentAndHundredOnlyAtTheEnd() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: container.mainContext) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        let last = model.chapters.count - 1
        let length = try XCTUnwrap(model.rendered(chapter: last)).attributed.length
        XCTAssertGreaterThan(length, 2)

        model.didShowPage(chapter: last, page: 0, pageCount: 2, firstOffset: 0, endOffset: length / 2)
        XCTAssertFalse(model.isAtEnd)
        XCTAssertFalse(model.progressPercent.contains(","), "no tenths: \(model.progressPercent)")
        XCTAssertNotEqual(model.progressPercent, "100 %")

        model.didShowPage(chapter: last, page: 1, pageCount: 2, firstOffset: length / 2, endOffset: length)
        XCTAssertTrue(model.isAtEnd)
        XCTAssertEqual(model.progressPercent, "100 %")
    }

    func testScrollModeBookmarkFollowsTheTapeAndShowsInTheMargin() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: context) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)

        let controller = ContinuousReaderController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        model.show(chapter: 1)
        controller.update(style: model.style, highlights: [], decorationsToken: 0, navigation: model.navigation)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100)) // position reports arrive asynchronously
        XCTAssertEqual(model.visibleRange?.chapter, 1)

        model.toggleBookmark(in: [], context: context)
        let bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        let bookmark = try XCTUnwrap(bookmarks.first)
        XCTAssertEqual(bookmark.chapterIndex, 1)
        XCTAssertTrue(model.bookmarkOnScreen(in: bookmarks) === bookmark, "the icon fills right away")

        // A ribbon marks the bookmarked line in the margin of the tape.
        controller.update(style: model.style, highlights: [], decorationsToken: 0, navigation: model.navigation, bookmarks: model.bookmarkOffsets(bookmarks))
        controller.view.layoutIfNeeded()
        let table = controller.tableView
        let ribbons = table.visibleCells.compactMap { $0 as? ChunkCell }.flatMap(\.ribbonFrames)
        XCTAssertEqual(ribbons.count, 1)
        if let ribbon = ribbons.first {
            XCTAssertGreaterThan(ribbon.minX, 390 - 24 - 1, "in the right margin, not over the text")
        }

        // Scrolling on: the bookmarked line leaves the screen and the icon empties, live.
        let start = table.contentOffset.y
        table.setContentOffset(CGPoint(x: 0, y: start + table.bounds.height * 1.5), animated: false)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(model.bookmarkOnScreen(in: bookmarks))

        // Back to the place: filled again, so you find where you were.
        table.setContentOffset(CGPoint(x: 0, y: start), animated: false)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.bookmarkOnScreen(in: bookmarks) === bookmark)
    }

    func testQuickTagCreatesATaggedHighlight() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: context) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        let text = try XCTUnwrap(model.rendered(chapter: 1)).text.string as NSString
        let range = text.range(of: "белый")
        let highlight = try XCTUnwrap(model.createHighlight(for: ChapterRange(chapter: 1, range: range), color: .lilac, tags: ["#Свет", "свет"], context: context))
        XCTAssertEqual(highlight.tags, ["свет"])
        XCTAssertEqual(highlight.color, .lilac)
        let catalog = try context.fetch(FetchDescriptor<TagRecord>()).map(\.name)
        XCTAssertTrue(catalog.contains("свет"))
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

    // MARK: Continuous scroll

    func testChunksCoverTheChapterAndHideTheTrailingParagraphBreak() throws {
        let chapter = try renderedSampleChapters(fontSize: 24)[1]
        let chunks = Paginator.paginate(chapter, pageSize: CGSize(width: 260, height: 500))
        XCTAssertGreaterThan(chunks.count, 1)
        let text = chapter.string as NSString
        for range in chunks.ranges {
            let content = Paginator.chunkContent(of: chapter, range: range)
            let endsWithBreak = text.character(at: NSMaxRange(range) - 1) == 0x0A
            XCTAssertEqual(content.length, range.length - (endsWithBreak && range.length > 1 ? 1 : 0))
            XCTAssertFalse(content.string.hasSuffix("\n"))
            if range.location > 0, text.character(at: range.location - 1) != 0x0A {
                let style = try XCTUnwrap(content.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
                XCTAssertEqual(style.firstLineHeadIndent, style.headIndent, "a continued paragraph has no first-line indent")
            }
        }
    }

    func testContinuousScrollShowsNeighbourChaptersWithoutMovingTheReader() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: container.mainContext) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.35), initialHighlight: nil)

        let controller = ContinuousReaderController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()

        model.show(chapter: 2)
        controller.update(style: model.style, highlights: [], decorationsToken: 0, navigation: model.navigation)
        controller.view.layoutIfNeeded()

        // The previous chapter was inserted above and the offset compensated: chapter 2 is still on top.
        XCTAssertTrue(controller.loadedChapterIndices.contains(1))
        XCTAssertTrue(controller.loadedChapterIndices.contains(2))
        XCTAssertEqual(controller.loadedChapterIndices, controller.loadedChapterIndices.sorted())
        let top = try XCTUnwrap(controller.visiblePosition)
        XCTAssertEqual(top.chapter, 2)
        XCTAssertEqual(top.offset, 0)

        // Scrolling down keeps loading the following chapters, in order, up to the end of the book.
        for _ in 0..<12 {
            let table = controller.tableView
            let bottom = max(0, table.contentSize.height - table.bounds.height)
            table.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            controller.view.layoutIfNeeded()
        }
        XCTAssertEqual(controller.loadedChapterIndices.last, model.chapters.count - 1)
        let indices = controller.loadedChapterIndices
        XCTAssertEqual(indices, Array((indices.first ?? 0)...(indices.last ?? 0)), "loaded chapters are contiguous")
    }

    // MARK: Appearance

    func testReaderFontsExistWithCyrillic() {
        // The two system designs and Georgia ship with every iOS; the rest only if installed.
        XCTAssertTrue(ReaderFont.available.contains(.sourceSerif), "Source Serif 4 is bundled and registered")
        XCTAssertTrue(ReaderFont.available.contains(.newYork))
        XCTAssertTrue(ReaderFont.available.contains(.sanFrancisco))
        XCTAssertTrue(ReaderFont.available.contains(.georgia), "families: \(UIFont.familyNames.sorted())")
        for font in ReaderFont.allCases where !font.isInstalled {
            // A missing family must fall back to the book serif, not to an arbitrary font.
            XCTAssertEqual(font.font(size: 17).familyName, ReaderFont.newYork.font(size: 17).familyName)
        }
        for font in ReaderFont.available {
            let uiFont = font.font(size: 17)
            if let family = font.familyName {
                XCTAssertEqual(uiFont.familyName, family, "\(font.title) is installed")
            }
            // Every book font must draw Cyrillic itself, without falling back to another font.
            let ctFont = uiFont as CTFont
            var glyphs = [CGGlyph](repeating: 0, count: 6)
            let characters = Array("Жёлудь".utf16)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, characters.count), "\(font.title) has Cyrillic")
        }
    }

    func testThemeAndTypographyChangeTheStyleKey() {
        let base = ReaderStyle(fontSize: 19, lineSpacing: 1.4)
        var dark = base
        dark.theme = .black
        var wide = base
        wide.margins = .wide
        var ragged = base
        ragged.justified = false
        var spaced = base
        spaced.letterSpacing = .wide
        XCTAssertEqual(Set([base.key, dark.key, wide.key, ragged.key, spaced.key]).count, 5)
        XCTAssertEqual(ReaderTheme.system.resolved(for: .dark), .wood)
        XCTAssertEqual(ReaderTheme.system.resolved(for: .light), .paper)
        XCTAssertTrue(ReaderTheme.black.isDark)
        XCTAssertFalse(ReaderTheme.white.isDark)
    }

    func testEveryStyleKeepsTheCharacterMapExact() throws {
        let book = try FB2Parser.parse(sampleData()).book
        let text = ChapterText(chapter: book.chapters[1])
        for font in ReaderFont.allCases {
            for theme in [ReaderTheme.white, .black] {
                let style = ReaderStyle(fontSize: 21, lineSpacing: 1.65, font: font, theme: theme, justified: font != .ptSans, margins: .wide)
                let rendered = ChapterRenderer.render(text, book: book, style: style)
                XCTAssertEqual(rendered.string, text.string)
            }
        }
    }

    func testPageNumberingMatchesThePagesShown() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: container.mainContext) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 22, lineSpacing: 1.4), initialHighlight: nil)
        let size = CGSize(width: 320, height: 520)
        model.requestPageNumbering(layoutKey: "test", pageSize: size)
        for _ in 0..<100 where model.pageNumbering == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        let numbering = try XCTUnwrap(model.pageNumbering)
        XCTAssertEqual(numbering.layoutKey, "test")
        // The background pass counts exactly the pages page mode shows.
        let expected = model.chapters.indices.map { Paginator.paginate(try! XCTUnwrap(model.rendered(chapter: $0)).attributed, pageSize: size).count }
        XCTAssertEqual(numbering.counts, expected)
        XCTAssertEqual(numbering.total, expected.reduce(0, +))
        XCTAssertEqual(numbering.pageNumber(chapter: 0, page: 0), 1)
        XCTAssertEqual(numbering.pageNumber(chapter: 1, page: 0), expected[0] + 1)
        XCTAssertNil(numbering.pageNumber(chapter: 1, page: expected[1]))
    }

    func testProgressSliderJumpsToTheRightChapter() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: container.mainContext) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        model.go(toProgression: 0.999)
        XCTAssertEqual(model.chapterIndex, model.chapters.count - 1)
        model.go(toProgression: 0)
        XCTAssertEqual(model.chapterIndex, 0)
        XCTAssertEqual(model.navigation?.utf16Offset, 0)
        XCTAssertEqual(model.chapterTitle(atProgression: 0.999), model.chapters.last?.title)
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

    // MARK: Easy reading (iteration 4)

    func testEasyReadingFontsAreBundled() {
        XCTAssertTrue(ReaderFont.available.contains(.andika), "families: \(UIFont.familyNames.sorted())")
        XCTAssertTrue(ReaderFont.available.contains(.openDyslexic), "families: \(UIFont.familyNames.sorted())")
        XCTAssertTrue(ReaderFont.andika.font(size: 17, traits: .traitItalic).fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertTrue(ReaderFont.openDyslexic.font(size: 17, weight: .semibold).fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testFontWithoutItalicGetsASlantForEmphasis() throws {
        let book = try FB2Parser.parse(sampleData()).book
        let text = ChapterText(chapter: book.chapters[1])
        let white = (text.string as NSString).range(of: "белый")
        XCTAssertNotEqual(white.location, NSNotFound)

        var style = ReaderStyle(fontSize: 19, lineSpacing: 1.4, font: .openDyslexic)
        var rendered = ChapterRenderer.render(text, book: book, style: style)
        XCTAssertEqual(rendered.attribute(.obliqueness, at: white.location, effectiveRange: nil) as? CGFloat, 0.18)
        XCTAssertNil(rendered.attribute(.obliqueness, at: 0, effectiveRange: nil), "only emphasis is slanted")

        style.font = .sourceSerif // has a real italic
        rendered = ChapterRenderer.render(text, book: book, style: style)
        XCTAssertNil(rendered.attribute(.obliqueness, at: white.location, effectiveRange: nil))
    }

    func testLetterSpacingWidensLettersAndWordsWithoutChangingTheText() throws {
        let book = try FB2Parser.parse(sampleData()).book
        let text = ChapterText(chapter: book.chapters[1])
        var style = ReaderStyle(fontSize: 20, lineSpacing: 1.85, justified: false, letterSpacing: .wide)
        let rendered = ChapterRenderer.render(text, book: book, style: style)
        XCTAssertEqual(rendered.string, text.string, "offsets of highlights stay valid")

        let string = text.string as NSString
        let space = string.range(of: " ").location
        let letter = string.range(of: "белый").location
        let letterKern = try XCTUnwrap(rendered.attribute(.kern, at: letter, effectiveRange: nil) as? CGFloat)
        let spaceKern = try XCTUnwrap(rendered.attribute(.kern, at: space, effectiveRange: nil) as? CGFloat)
        XCTAssertEqual(letterKern, 0.08 * 20, accuracy: 0.001)
        XCTAssertEqual(spaceKern, letterKern * ReaderLetterSpacing.wordGapFactor, accuracy: 0.001)

        // Ragged right means whole words: no hyphenation, no justification.
        let body = string.range(of: "Обоз подошёл").location
        let paragraph = try XCTUnwrap(rendered.attribute(.paragraphStyle, at: body, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.hyphenationFactor, 0)
        XCTAssertNotEqual(paragraph.alignment, .justified)
        XCTAssertEqual(paragraph.lineHeightMultiple, 1.85, accuracy: 0.001)

        style.letterSpacing = .normal
        let plain = ChapterRenderer.render(text, book: book, style: style)
        XCTAssertNil(plain.attribute(.kern, at: letter, effectiveRange: nil))
        // Wider letters take more room: at least as many pages for the same chapter.
        let size = CGSize(width: 320, height: 520)
        XCTAssertGreaterThanOrEqual(Paginator.paginate(rendered, pageSize: size).count, Paginator.paginate(plain, pageSize: size).count)
    }

    func testEasyReadingSwitchAppliesThePresetAndGivesTheOldLookBack() {
        let book = EasyReading.Settings(justified: true, letterSpacing: .normal, spacing: .normal, theme: .white)
        XCTAssertFalse(EasyReading.isOn(book))
        let easy = EasyReading.applied(to: book)
        XCTAssertTrue(EasyReading.isOn(easy))
        XCTAssertEqual(easy, EasyReading.Settings(justified: false, letterSpacing: .wide, spacing: .airy, theme: .paper))

        // Wider than the preset is still "on" and is not narrowed.
        var wider = easy
        wider.letterSpacing = .wider
        XCTAssertTrue(EasyReading.isOn(wider))
        XCTAssertEqual(EasyReading.applied(to: wider).letterSpacing, .wider)

        // Off: the saved settings come back, white page included.
        let saved = EasyReading.decode(EasyReading.encode(book))
        XCTAssertEqual(saved, book)
        XCTAssertEqual(EasyReading.restored(from: saved, current: easy), book)
        // A theme picked meanwhile stays.
        var black = easy
        black.theme = .black
        XCTAssertEqual(EasyReading.restored(from: saved, current: black).theme, .black)
        // Nothing saved: the usual book look.
        XCTAssertEqual(
            EasyReading.restored(from: nil, current: easy),
            EasyReading.Settings(justified: true, letterSpacing: .normal, spacing: .normal, theme: .paper)
        )
        XCTAssertNil(EasyReading.decode("garbage"))
    }

    func testReadingPaceIsLearntFromPageTurnsAndGivesTimeLeft() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: container.mainContext) else {
            return XCTFail("expected a new book")
        }
        let suite = "chitall-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ReaderModel(book: book, files: files, defaults: defaults)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        model.now = { clock }
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)

        let index = try XCTUnwrap(model.wordIndex(chapter: 1))
        XCTAssertGreaterThan(index.count, 45)
        let next = index.starts[44]
        model.didShowPage(chapter: 1, page: 0, pageCount: 2, firstOffset: 0, endOffset: next)
        XCTAssertEqual(model.chapterTimeLeft, ReadingPace().chapterLeftLabel(words: index.count))

        clock += 20 // 44 words in 20 s: 132 words a minute
        model.didShowPage(chapter: 1, page: 1, pageCount: 2, firstOffset: next, endOffset: next + 10)
        XCTAssertEqual(model.pace.measuredWords, 44)
        XCTAssertEqual(model.pace.wordsPerMinute, 132, accuracy: 0.5)
        XCTAssertNotNil(defaults.data(forKey: ReaderPreferences.paceKey), "the pace is kept for the next book")
        XCTAssertNotNil(model.chapterTimeLeft)

        // A jump from the contents is not reading: it teaches nothing.
        model.show(chapter: 3)
        clock += 1
        model.didShowPage(chapter: 3, page: 0, pageCount: 1, firstOffset: 0, endOffset: 50)
        XCTAssertEqual(model.pace.measuredWords, 44)

        let reopened = ReaderModel(book: book, files: files, defaults: defaults)
        XCTAssertEqual(reopened.pace, model.pace)
    }

    func testReopenedBookShowsWhereTheReaderStopped() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: context) else {
            return XCTFail("expected a new book")
        }
        let first = ReaderModel(book: book, files: files)
        await first.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        XCTAssertNil(first.resumeSnippet, "a new book starts at the beginning: nothing to recall")
        let text = try XCTUnwrap(first.rendered(chapter: 1)).text.string as NSString
        let place = text.range(of: "Стражник был молод")
        first.saveReadingPosition(chapter: 1, atUTF16: place.location)

        let reopened = ReaderModel(book: book, files: files)
        await reopened.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        let snippet = try XCTUnwrap(reopened.resumeSnippet)
        let before = text.substring(to: place.location).split(whereSeparator: \.isWhitespace).suffix(3).joined(separator: " ")
        XCTAssertTrue(snippet.hasSuffix(before), "'\(snippet)' ends with the words right before the place: '\(before)'")
        XCTAssertLessThanOrEqual(snippet.count, 221)

        // Reading on (a page turn or a drag) puts the card away.
        let moves = reopened.userMoves
        reopened.userDidMove()
        XCTAssertEqual(reopened.userMoves, moves + 1)
        reopened.dismissResume()
        XCTAssertNil(reopened.resumeSnippet)

        // Opening a highlight goes straight there: no card.
        let selection = ChapterRange(chapter: 1, range: text.range(of: "белый"))
        let highlight = try XCTUnwrap(reopened.createHighlight(for: selection, color: .azure, context: context))
        let viaHighlight = ReaderModel(book: book, files: files)
        await viaHighlight.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: highlight)
        XCTAssertNil(viaHighlight.resumeSnippet)
    }

    func testFocusRulerLightsTheParagraphAtTheReadingLine() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: container.mainContext) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        let controller = ContinuousReaderController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        model.show(chapter: 1)
        controller.update(style: model.style, highlights: [], decorationsToken: 0, navigation: model.navigation)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(controller.focusDim.isHidden, "off by default")

        controller.focusRuler = true
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.focusDim.isHidden)
        let lit = try XCTUnwrap(controller.focusDim.litRange)
        let table = controller.tableView
        let insets = table.adjustedContentInset
        let readingY = insets.top + (table.bounds.height - insets.top - insets.bottom) * ContinuousReaderController.readingLine
        XCTAssertTrue(lit.contains(readingY), "the reading line \(readingY) is lit: \(lit)")
        XCTAssertGreaterThan(lit.upperBound - lit.lowerBound, 19)
        XCTAssertLessThan(lit.upperBound - lit.lowerBound, 844 * 0.5, "the rest of the screen is dimmed")

        // The band follows the tape.
        table.setContentOffset(CGPoint(x: 0, y: table.contentOffset.y + 300), animated: false)
        controller.view.layoutIfNeeded()
        let moved = try XCTUnwrap(controller.focusDim.litRange)
        XCTAssertTrue(moved.contains(readingY))

        controller.focusRuler = false
        XCTAssertTrue(controller.focusDim.isHidden)
    }

    func testPageFooterShowsTimeLeftInTheChapter() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: container.mainContext) else {
            return XCTFail("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        let controller = PagedReaderController(model: model)
        let label = controller.pageLabel(for: PageLocation(chapter: 1, page: 0), pageCount: 3, range: NSRange(location: 0, length: 10))
        XCTAssertTrue(label.hasPrefix("1 / 3 · ≈ "), label)
        XCTAssertTrue(label.hasSuffix("мин до конца главы"), label)
    }

    // MARK: Reading and words (iteration 5)

    private func openSample() async throws -> (ReaderModel, ModelContext) {
        let container = try ChitallStore.makeContainer(inMemory: true)
        retainedContainers.append(container)
        let context = container.mainContext
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files).importData(try sampleData(), originalFileName: "s.fb2", into: context) else {
            throw XCTSkip("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        return (model, context)
    }

    func testPauseTimerOnThePanelCountsDownAndTurnsOff() async throws {
        let (model, _) = try await openSample()
        var clock = Date(timeIntervalSince1970: 2_000_000)
        model.now = { clock }
        XCTAssertFalse(model.pauseTimer.isOn, "off until the reader picks a length")

        model.startPauseTimer(minutes: 15)
        XCTAssertEqual(model.pauseTimer.shortLabel(at: clock), "15 мин")
        XCTAssertEqual(model.pauseTimer.end, clock + 15 * 60)
        clock += 5 * 60 + 10
        XCTAssertEqual(model.pauseTimer.shortLabel(at: clock), "10 мин", "what is left shows next to the icon")
        XCTAssertEqual(model.pauseTimer.statusLabel(at: clock), "Пауза через 10 мин")

        // "Ещё 15 мин" / "Начать заново": a new stretch from now.
        model.startPauseTimer(minutes: 15)
        XCTAssertEqual(model.pauseTimer.end, clock + 15 * 60)
        XCTAssertTrue(model.pauseTimer.isDue(at: clock + 15 * 60))

        model.startPauseTimer(minutes: 0) // "Выключить"
        XCTAssertFalse(model.pauseTimer.isOn)
        XCTAssertNil(model.pauseTimer.shortLabel(at: clock))
    }

    func testSelectionMenuOffersTheMeaningOfAWord() throws {
        func titles(_ selectedText: String) -> [String] {
            ReaderEditMenu.make(
                for: ChapterRange(chapter: 1, range: NSRange(location: 0, length: selectedText.utf16.count)),
                selectedText: selectedText,
                decorations: [],
                suggestedActions: [],
                perform: { _ in },
                clearSelection: {}
            ).children.map { ($0 as? UIAction)?.title ?? ($0 as? UIMenu)?.title ?? "" }
        }
        let word = titles("«Казённую».")
        XCTAssertEqual(Array(word.prefix(3)), ["Выделить", "Мысль…", "Значение"], "visible right away after a long press on a word")
        XCTAssertFalse(titles("Стражник был молод, в тулупе с чужого плеча.").contains("Значение"), "a sentence is not looked up")

        // The system dictionary: "Казённую" at the start of a sentence is found as "казённую".
        let found = DictionaryLookup.request(for: "Казённую") { $0 == "казённую" }
        XCTAssertTrue(found.found)
        XCTAssertEqual(found.term, "казённую")
        let exact = DictionaryLookup.request(for: "Бережск") { $0 == "Бережск" }
        XCTAssertEqual(exact.term, "Бережск")
        // No Russian dictionary on the phone: the card that says where to download it.
        let missing = DictionaryLookup.request(for: "пищаль") { _ in false }
        XCTAssertFalse(missing.found)
        XCTAssertEqual(missing.term, "пищаль")
    }

    func testParagraphModeShowsOneParagraphAndGoesOnThroughTheBook() async throws {
        let (model, _) = try await openSample()
        let controller = ParagraphReaderController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        model.show(chapter: 1)
        controller.update(style: model.style, decorations: [:], bookmarks: [:], navigation: model.navigation)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100)) // position reports arrive asynchronously

        let steps = try XCTUnwrap(model.paragraphSteps(chapter: 1))
        XCTAssertGreaterThan(steps.count, 3)
        let text = try XCTUnwrap(model.rendered(chapter: 1)).text.string as NSString
        func expected(_ step: Int) -> NSRange {
            NSRange(location: steps.ranges[step].lowerBound, length: steps.ranges[step].count)
        }
        XCTAssertEqual(controller.shownRange, expected(0))
        XCTAssertEqual(controller.fragment.textView.text, text.substring(with: expected(0)), "only this paragraph is on screen")
        XCTAssertEqual(model.visibleRange, ChapterRange(chapter: 1, range: expected(0)))
        XCTAssertTrue(controller.footerLabel().hasPrefix("абзац 1 из \(steps.count)"), controller.footerLabel())

        // Next by a tap or a swipe: the reading position follows and the reader's move is counted.
        let moves = model.userMoves
        controller.turn(forward: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.shownRange, expected(1))
        XCTAssertEqual(model.userMoves, moves + 1)
        XCTAssertEqual(model.visibleRange, ChapterRange(chapter: 1, range: expected(1)))
        XCTAssertNotNil(model.storedBook.readingPositionJSON, "the reading position is saved as in the other modes")

        // On through the end of the chapter into the next one, and back.
        for _ in 1..<steps.count { controller.turn(forward: true) }
        XCTAssertEqual(controller.location, PageLocation(chapter: 2, page: 0))
        controller.turn(forward: false)
        XCTAssertEqual(controller.location, PageLocation(chapter: 1, page: steps.count - 1))

        // A jump (contents, search, slider) opens the paragraph that holds the place.
        let place = text.range(of: "Стражник был молод")
        model.saveReadingPosition(chapter: 1, atUTF16: place.location + 20)
        model.navigateToCurrentPosition()
        controller.update(style: model.style, decorations: [:], bookmarks: [:], navigation: model.navigation)
        XCTAssertEqual(controller.location?.page, steps.index(containing: place.location + 20))
        XCTAssertEqual(controller.shownRange?.location, place.location, "the paragraph starts at its first word")
        XCTAssertGreaterThan(ReadingMode.paragraphScale, 1, "larger type than the chosen size")
    }

    func testParagraphModeKeepsHighlightsThoughtsAndBookmarks() async throws {
        let (model, context) = try await openSample()
        let controller = ParagraphReaderController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        let chapterText = try XCTUnwrap(model.rendered(chapter: 1)).text
        let text = chapterText.string as NSString
        let place = text.range(of: "Стражник был молод")
        model.show(chapter: 1, at: chapterText.position(atUTF16: place.location, forward: true))
        controller.update(style: model.style, decorations: [:], bookmarks: [:], navigation: model.navigation)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let shown = try XCTUnwrap(controller.shownRange)
        XCTAssertEqual(shown.location, place.location)

        // A selection on the paragraph screen is in chapter coordinates: an ordinary highlight.
        let word = text.range(of: "тулупе")
        let highlight = try XCTUnwrap(model.createHighlight(for: ChapterRange(chapter: 1, range: word), color: .ochre, context: context))
        highlight.note = "Чужой тулуп — новобранец."
        XCTAssertEqual(highlight.text, "тулупе")
        controller.update(style: model.style, decorations: model.decorationsAroundCurrentChapter(for: [highlight]), bookmarks: [:], navigation: model.navigation)
        let storage = controller.fragment.textView.textStorage
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: word.location - shown.location, effectiveRange: nil), "the highlight is painted")
        XCTAssertNotNil(storage.attribute(.underlineStyle, at: word.location - shown.location, effectiveRange: nil), "its thought is marked")

        // A bookmark marks this paragraph; the icon fills while it is on screen.
        model.toggleBookmark(in: [], context: context)
        let bookmarks = try context.fetch(FetchDescriptor<Bookmark>())
        let bookmark = try XCTUnwrap(bookmarks.first)
        XCTAssertTrue(model.bookmarkOnScreen(in: bookmarks) === bookmark)
        controller.update(style: model.style, decorations: [:], bookmarks: model.bookmarkOffsetsAroundCurrentChapter(bookmarks), navigation: model.navigation)
        XCTAssertTrue(controller.isBookmarkShown)
        controller.turn(forward: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.isBookmarkShown)
        XCTAssertNil(model.bookmarkOnScreen(in: bookmarks))
        model.go(to: bookmark)
        controller.update(style: model.style, decorations: [:], bookmarks: model.bookmarkOffsetsAroundCurrentChapter(bookmarks), navigation: model.navigation)
        XCTAssertEqual(controller.shownRange, shown, "the bookmark opens its paragraph")
        XCTAssertTrue(controller.isBookmarkShown)
    }

    func testThoughtByVoiceAddsToTheThoughtAndExplainsItself() throws {
        // iOS ends an app that uses the microphone or speech recognition without saying why.
        for key in ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"] {
            let reason = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: key) as? String, key)
            XCTAssertTrue(reason.contains("iPhone"), "says that the voice stays on the phone: \(reason)")
        }

        var thought = ""
        let dictation = ThoughtDictation()
        dictation.onText = { thought = $0 }
        dictation.begin(with: "Ефим молчит")
        for partial in ["потому", "потому что", "потому что боится досмотра"] {
            dictation.receive(partial)
        }
        XCTAssertEqual(thought, "Ефим молчит. Потому что боится досмотра", "what was written stays, the words are added once")
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertFalse(dictation.isListening)

        // No recognizer for Russian: an honest hint instead of a server.
        let reason = try XCTUnwrap(ThoughtDictation.unavailableReason(nil))
        XCTAssertTrue(reason.contains("клавиатуре"), reason)
        XCTAssertEqual(ThoughtDictation.locale.identifier, "ru-RU")
    }
}

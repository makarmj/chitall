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
        XCTAssertEqual(Set([base.key, dark.key, wide.key, ragged.key]).count, 4)
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
}

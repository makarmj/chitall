import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Chitall

/// EPUB in the app: import into the library, the reader's highlight and position round trip,
/// notes, and the three reading modes. The EPUB parser itself is covered by ChitallCoreTests.
@MainActor
final class EPUBAppTests: XCTestCase {
    private var temporaryRoot: URL!
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

    private func openEPUB() async throws -> (ReaderModel, ModelContext, BookFileStore) {
        let container = try ChitallStore.makeContainer(inMemory: true)
        retainedContainers.append(container)
        let context = container.mainContext
        let files = try makeFiles()
        guard case let .imported(book) = try await BookImportService(files: files)
            .importData(TestEPUB.make(), originalFileName: "yarmarka.epub", into: context) else {
            throw XCTSkip("expected a new book")
        }
        let model = ReaderModel(book: book, files: files)
        await model.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: nil)
        return (model, context, files)
    }

    // MARK: Import

    func testEPUBIsOfferedImportedAndShownInTheLibrary() async throws {
        XCTAssertTrue(BookFileTypes.importable.contains(.epub), "the Files picker offers EPUB")
        XCTAssertEqual(UTType(filenameExtension: "epub"), .epub)
        let documentTypes = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let handled = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(handled.contains("org.idpf.epub-container"), "«Открыть в Chitall» for EPUB: \(handled)")

        let container = try ChitallStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let files = try makeFiles()
        let importer = BookImportService(files: files)
        let data = try TestEPUB.make()
        guard case let .imported(book) = try await importer.importData(data, originalFileName: "yarmarka.epub", into: context) else {
            return XCTFail("expected a new book")
        }
        XCTAssertEqual(book.title, "Ярмарка у реки")
        XCTAssertEqual(book.authors, "Анна Тестова")
        XCTAssertEqual(book.language, "ru")
        XCTAssertEqual(book.chapterCount, 3)
        XCTAssertEqual(book.fingerprint, Fingerprint.of(data), "the fingerprint is SHA-256 of the .epub file")
        XCTAssertTrue(book.fileName.hasSuffix(".epub"))
        XCTAssertEqual(try files.readBook(named: book.fileName), data, "the exact file is kept")
        XCTAssertEqual(book.format, .epub)
        XCTAssertEqual(book.formatName, "EPUB")
        let cover = try XCTUnwrap(book.coverFileName, "the cover is saved for the library")
        XCTAssertNotNil(UIImage(contentsOfFile: files.coverURL(named: cover).path))

        guard case .alreadyInLibrary = try await importer.importData(data, originalFileName: "copy.epub", into: context) else {
            return XCTFail("expected duplicate detection by fingerprint")
        }
        XCTAssertEqual(BookImportService.title(fromFileName: "Ярмарка.epub"), "Ярмарка")
    }

    func testProtectedEPUBGivesARussianMessage() async throws {
        let container = try ChitallStore.makeContainer(inMemory: true)
        do {
            _ = try await BookImportService(files: try makeFiles())
                .importData(TestEPUB.make(encrypted: true), originalFileName: "drm.epub", into: container.mainContext)
            XCTFail("expected an error")
        } catch {
            let message = BookImportService.message(for: error)
            XCTAssertTrue(message.hasPrefix("Книга защищена DRM"), message)
        }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<StoredBook>()), 0)
    }

    // MARK: Reader

    func testEPUBReaderHighlightsNotesAndReadingPosition() async throws {
        let (model, context, files) = try await openEPUB()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.chapters.map(\.title), ["Обложка", "Глава первая. Ярмарка", "Глава вторая. Дорога"])

        model.show(chapter: 1)
        let rendered = try XCTUnwrap(model.rendered)
        let word = (rendered.text.string as NSString).range(of: "толстую")
        let highlight = try XCTUnwrap(model.createHighlight(for: ChapterRange(chapter: 1, range: word), color: .azure, context: context))
        XCTAssertEqual(highlight.text, "толстую")
        XCTAssertEqual(highlight.chapterTitle, "Глава первая. Ярмарка")
        let locator = try XCTUnwrap(highlight.locator)
        XCTAssertEqual(locator.format, .epub)
        XCTAssertEqual(locator.start.resource, "OEBPS/ch1.xhtml")
        XCTAssertEqual(locator.start.path, "/html/body[1]/p[2]")
        XCTAssertEqual(model.decorations(for: [highlight], chapter: 1).first?.range, word)
        XCTAssertEqual(highlight.materialItem()?.locator.format, .epub, "exports carry the format")

        // The footnote number opens its card, as in FB2.
        var noteLinks: [URL] = []
        rendered.attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.attributed.length)) { value, _, _ in
            if let url = value as? URL, url.scheme == ChapterRenderer.noteScheme { noteLinks.append(url) }
        }
        XCTAssertEqual(noteLinks.count, 1)
        XCTAssertEqual(ChapterRenderer.linkURL("Text/part 1.html#r1", isNote: false).flatMap(ChapterRenderer.linkTarget), "Text/part 1.html#r1")
        XCTAssertEqual(ChapterRenderer.linkURL("n1", isNote: true).flatMap(ChapterRenderer.linkTarget), "n1", "FB2 ids as before")
        guard case let .note(note) = model.target(of: try XCTUnwrap(noteLinks.first)) else {
            return XCTFail("the note link should open a note")
        }
        XCTAssertEqual(note.text, "Ярмарка шла три дня.")
        XCTAssertEqual(note.title, "1")

        // The reading position survives closing the book.
        let paragraph = (rendered.text.string as NSString).range(of: "Ефим купил")
        model.saveReadingPosition(chapter: 1, atUTF16: paragraph.location)
        let reopened = ReaderModel(book: model.storedBook, files: files)
        await reopened.load(style: ReaderStyle(fontSize: 22, lineSpacing: 1.5), initialHighlight: nil)
        XCTAssertEqual(reopened.chapterIndex, 1)
        XCTAssertEqual(reopened.navigation?.utf16Offset, paragraph.location)

        // "Открыть в книге" from Materials.
        let fromMaterials = ReaderModel(book: model.storedBook, files: files)
        await fromMaterials.load(style: ReaderStyle(fontSize: 19, lineSpacing: 1.4), initialHighlight: highlight)
        XCTAssertEqual(fromMaterials.chapterIndex, 1)
    }

    func testEPUBReadsInPagesScrollAndParagraphModes() async throws {
        let (model, context, _) = try await openEPUB()

        // Pages: every character of every chapter, including the cover picture, on exactly one page.
        for index in model.chapters.indices {
            let chapter = try XCTUnwrap(model.rendered(chapter: index)).attributed
            let pages = Paginator.paginate(chapter, pageSize: CGSize(width: 330, height: 420))
            var expected = 0
            for range in pages.ranges {
                XCTAssertEqual(range.location, expected)
                expected = NSMaxRange(range)
            }
            XCTAssertEqual(expected, chapter.length, "chapter \(index)")
        }

        // Scroll: one tape through the whole book.
        let tape = ContinuousReaderController(model: model)
        tape.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        tape.view.layoutIfNeeded()
        model.show(chapter: 1)
        tape.update(style: model.style, highlights: [], decorationsToken: 0, navigation: model.navigation)
        tape.view.layoutIfNeeded()
        XCTAssertEqual(tape.visiblePosition?.chapter, 1)
        for _ in 0..<8 {
            let table = tape.tableView
            table.setContentOffset(CGPoint(x: 0, y: max(0, table.contentSize.height - table.bounds.height)), animated: false)
            tape.view.layoutIfNeeded()
        }
        XCTAssertEqual(tape.loadedChapterIndices.last, model.chapters.count - 1)

        // One paragraph at a time, with a highlight painted on it.
        let controller = ParagraphReaderController(model: model)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        model.show(chapter: 1)
        controller.update(style: model.style, decorations: [:], bookmarks: [:], navigation: model.navigation)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let steps = try XCTUnwrap(model.paragraphSteps(chapter: 1))
        XCTAssertGreaterThanOrEqual(steps.count, 3)
        XCTAssertEqual(controller.shownRange, NSRange(location: steps.ranges[0].lowerBound, length: steps.ranges[0].count))
        controller.turn(forward: true)
        try await Task.sleep(for: .milliseconds(100))
        let shown = try XCTUnwrap(controller.shownRange)
        XCTAssertEqual(shown, NSRange(location: steps.ranges[1].lowerBound, length: steps.ranges[1].count))
        let text = try XCTUnwrap(model.rendered(chapter: 1)).text.string as NSString
        XCTAssertTrue(text.substring(with: shown).hasPrefix("Писарь записывал"), text.substring(with: shown))

        let word = text.range(of: "ворчал")
        let highlight = try XCTUnwrap(model.createHighlight(for: ChapterRange(chapter: 1, range: word), color: .ochre, context: context))
        controller.update(style: model.style, decorations: model.decorationsAroundCurrentChapter(for: [highlight]), bookmarks: [:], navigation: model.navigation)
        let storage = controller.fragment.textView.textStorage
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: word.location - shown.location, effectiveRange: nil), "the highlight is painted")
    }
}

/// A small EPUB 3 written for the tests, packed into a stored (uncompressed) ZIP in memory.
@MainActor
enum TestEPUB {
    static func make(encrypted: Bool = false) throws -> Data {
        var entries: [(String, Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8)),
            ("OEBPS/package.opf", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="uid">urn:uuid:chitall-app-test</dc:identifier>
                <dc:title>Ярмарка у реки</dc:title>
                <dc:creator>Анна Тестова</dc:creator>
                <dc:language>ru</dc:language>
                <meta property="dcterms:modified">2026-10-21T00:00:00Z</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
                <item id="cover-page" href="cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="cover-page"/><itemref idref="ch1"/><itemref idref="ch2"/></spine>
            </package>
            """.utf8)),
            ("OEBPS/nav.xhtml", page("""
            <nav epub:type="toc"><ol>
              <li><a href="ch1.xhtml">Глава первая. Ярмарка</a></li>
              <li><a href="ch2.xhtml">Глава вторая. Дорога</a></li>
            </ol></nav>
            """)),
            ("OEBPS/cover.png", cover()),
            ("OEBPS/cover.xhtml", page(#"<div><img src="cover.png" alt="Обложка"/></div>"#)),
            ("OEBPS/ch1.xhtml", page("""
            <h1>Глава первая. Ярмарка</h1>
            <p>На ярмарке торговали <em>солью</em>, мёдом и пушниной, а у самого берега чинили лодки.<a epub:type="noteref" href="#n1">1</a></p>
            <p>Писарь записывал цены в толстую книгу и ворчал, что купцы снова врут о весе мешков.</p>
            <p>Ефим купил подкову на счастье и долго держал её в руке, будто она была ещё тёплой.</p>
            <aside epub:type="footnote" id="n1"><p>Ярмарка шла три дня.</p></aside>
            """)),
            ("OEBPS/ch2.xhtml", page("""
            <h1>Глава вторая. Дорога</h1>
            <p>Обоз вышел затемно, и до самого рассвета никто не проронил ни слова, даже собаки.</p>
            <p>К полудню показалась река, широкая и спокойная, а за ней — колокольня соседнего села.</p>
            """)),
        ]
        if encrypted {
            entries.append(("META-INF/encryption.xml", Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData>
                <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
                <enc:CipherData><enc:CipherReference URI="OEBPS/ch1.xhtml"/></enc:CipherData>
              </enc:EncryptedData>
            </encryption>
            """.utf8)))
        }
        return zip(entries)
    }

    private static func page(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="ru">
        <head><title>Ярмарка</title></head>
        <body>
        \(body)
        </body>
        </html>
        """.utf8)
    }

    private static func cover() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30))
        return renderer.pngData { context in
            UIColor.brown.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        }
    }

    /// ZIP with "stored" entries only: local headers, central directory, end record.
    private static func zip(_ entries: [(String, Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        for (name, data) in entries {
            let nameBytes = Data(name.utf8)
            let crc = CRC32.checksum(data)
            let offset = UInt32(archive.count)
            let common = le16(20) + le16(0x0800) + le16(0) + le16(0) + le16(0x21) + le32(crc)
                + le32(UInt32(data.count)) + le32(UInt32(data.count)) + le16(nameBytes.count) + le16(0)
            archive += le32(0x0403_4B50) + common + nameBytes + data
            directory += le32(0x0201_4B50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
        }
        let directoryOffset = UInt32(archive.count)
        archive += directory
        archive += le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
            + le32(UInt32(directory.count)) + le32(directoryOffset) + le16(0)
        return archive
    }
}

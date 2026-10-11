import Foundation
import Observation
import SwiftData

/// "Show this place": a chapter and a display offset inside it. Both reading modes consume it.
struct NavigationRequest: Equatable {
    enum Placement: Equatable {
        /// The offset becomes the first visible line / is on the shown page (reading position).
        case top
        /// The offset lands in the upper third (a highlight or a search result).
        case upperThird
    }

    let id = UUID()
    let chapter: Int
    let utf16Offset: Int
    let placement: Placement
}

struct HighlightDecoration: Equatable {
    enum Kind: Equatable {
        case highlight
        case searchHit
    }

    let id: UUID
    /// Display range in chapter coordinates (UTF-16).
    let range: NSRange
    let color: HighlightColor
    let hasNote: Bool
    var kind: Kind = .highlight
}

enum ReadingMode: String, CaseIterable, Identifiable {
    case pages
    case scroll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pages: return "Страницы"
        case .scroll: return "Прокрутка"
        }
    }
}

/// State of an open book: the parsed model, the current chapter and the bridge between
/// display ranges, block positions and stored locators. Shared by both reading modes.
@MainActor
@Observable
final class ReaderModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    struct PageStatus: Equatable {
        let page: Int
        let pageCount: Int
    }

    let storedBook: StoredBook
    private(set) var phase: Phase = .loading
    private(set) var book: ReadableBook?
    private(set) var chapterIndex = 0
    private(set) var styleKey = ""
    private(set) var navigation: NavigationRequest?
    private(set) var pageStatus: PageStatus?
    private(set) var searchHighlight: ChapterRange?
    var chromeVisible = true
    /// The query of the search sheet, kept while the book is open.
    @ObservationIgnored var lastSearchQuery = ""

    private let files: BookFileStore
    @ObservationIgnored private var service: LocatorService?
    @ObservationIgnored private var style = ReaderStyle(fontSize: 19, lineSpacing: 1.35)
    @ObservationIgnored private var renderCache: [Int: RenderedChapter] = [:]
    @ObservationIgnored private var resolutions: [UUID: (json: String, result: LocatorResolution)] = [:]
    @ObservationIgnored private var lastPosition: (chapter: Int, utf16: Int)?

    init(book: StoredBook, files: BookFileStore) {
        self.storedBook = book
        self.files = files
    }

    var isReady: Bool { phase == .ready }

    var chapters: [Chapter] { book?.chapters ?? [] }

    var currentChapter: Chapter? {
        guard let book, book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    /// The current chapter, rendered in the current typography (scroll mode shows this).
    var rendered: RenderedChapter? {
        _ = styleKey // re-render dependants when the typography changes
        return rendered(chapter: chapterIndex)
    }

    // MARK: Loading

    func load(style: ReaderStyle, initialHighlight: Highlight?) async {
        guard book == nil else { return }
        self.style = style
        styleKey = style.key
        let fileName = storedBook.fileName
        let fingerprint = storedBook.fingerprint
        let files = self.files
        do {
            let parsed = try await Task.detached(priority: .userInitiated) { () throws -> ReadableBook in
                try FB2Parser.parse(files.readBook(named: fileName)).book
            }.value
            book = parsed
            service = LocatorService(book: parsed, fingerprint: fingerprint)

            if let initialHighlight, let range = resolve(initialHighlight)?.range,
               let chapter = parsed.chapterIndex(ofBlock: range.start.block) {
                show(chapter: chapter, at: range.start, placement: .upperThird)
            } else if let position = savedReadingPosition(), let chapter = parsed.chapterIndex(ofBlock: position.block) {
                show(chapter: chapter, at: position, placement: .top)
            } else {
                show(chapter: 0)
            }
            storedBook.lastOpenedAt = .now
            phase = .ready
        } catch {
            phase = .failed(
                "Не удалось открыть файл книги. Возможно, он повреждён или был удалён. "
                    + "Удалите книгу из библиотеки и импортируйте её снова — выделения сохранятся.\n\n"
                    + BookImportService.message(for: error)
            )
        }
    }

    private func savedReadingPosition() -> BlockPosition? {
        guard let locator = storedBook.readingPosition, let service else { return nil }
        if case let .caret(position) = service.resolve(locator) { return position }
        return nil
    }

    // MARK: Chapters and typography

    /// A chapter rendered in the current typography; cached, at most a few chapters at a time.
    func rendered(chapter index: Int) -> RenderedChapter? {
        guard let book, book.chapters.indices.contains(index) else { return nil }
        if let cached = renderCache[index], cached.styleKey == style.key { return cached }
        let text = ChapterText(chapter: book.chapters[index])
        let rendered = RenderedChapter(
            chapterIndex: index,
            styleKey: style.key,
            attributed: ChapterRenderer.render(text, book: book, style: style),
            text: text
        )
        if renderCache.count >= 6 {
            let farthest = renderCache.keys.max { abs($0 - chapterIndex) < abs($1 - chapterIndex) }
            if let farthest { renderCache[farthest] = nil }
        }
        renderCache[index] = rendered
        return rendered
    }

    func show(chapter index: Int, at position: BlockPosition? = nil, placement: NavigationRequest.Placement = .top) {
        guard let text = rendered(chapter: index)?.text else { return }
        chapterIndex = index
        let offset = position.flatMap { text.utf16Offset(of: $0) } ?? 0
        navigation = NavigationRequest(chapter: index, utf16Offset: offset, placement: placement)
        lastPosition = (index, offset)
    }

    func showNextChapter() { show(chapter: chapterIndex + 1) }
    func showPreviousChapter() { show(chapter: chapterIndex - 1) }

    var hasNextChapter: Bool { chapterIndex + 1 < chapters.count }
    var hasPreviousChapter: Bool { chapterIndex > 0 }

    func go(toBlock ordinal: Int) {
        guard let chapter = book?.chapterIndex(ofBlock: ordinal) else { return }
        show(chapter: chapter, at: BlockPosition(block: ordinal, offset: 0), placement: .top)
    }

    /// Asks the active reading mode to show the last known position (after a mode switch).
    func navigateToCurrentPosition() {
        guard let position = lastPosition else { return }
        navigation = NavigationRequest(chapter: position.chapter, utf16Offset: position.utf16, placement: .top)
    }

    /// New typography: cached chapters are re-rendered on demand; views keep their place.
    func restyle(_ newStyle: ReaderStyle) {
        guard newStyle != style else { return }
        style = newStyle
        renderCache = [:]
        styleKey = newStyle.key
    }

    // MARK: Position reports from the views

    /// Page mode: the user turned to another page (possibly in another chapter).
    func didShowPage(chapter: Int, page: Int, pageCount: Int, firstOffset: Int) {
        if chapter != chapterIndex { chapterIndex = chapter }
        let status = PageStatus(page: page, pageCount: pageCount)
        if pageStatus != status { pageStatus = status }
        saveReadingPosition(chapter: chapter, atUTF16: firstOffset)
    }

    /// Continuous mode: the reader scrolled; `save` once scrolling has settled.
    func didScroll(chapter: Int, utf16Offset offset: Int, save: Bool) {
        if chapter != chapterIndex { chapterIndex = chapter }
        if pageStatus != nil { pageStatus = nil }
        if save {
            saveReadingPosition(chapter: chapter, atUTF16: offset)
        } else {
            lastPosition = (chapter, offset)
        }
    }

    func saveReadingPosition(chapter: Int, atUTF16 offset: Int) {
        lastPosition = (chapter, offset)
        guard let text = rendered(chapter: chapter)?.text, let service,
              let position = text.position(atUTF16: offset, forward: true),
              let locator = service.locator(at: position),
              let json = try? locator.jsonString() else { return }
        storedBook.readingPositionJSON = json
        storedBook.readingProgress = locator.progression
        storedBook.lastOpenedAt = .now
    }

    // MARK: Links

    enum LinkTarget {
        case note(NoteContent)
        case block(Int)
    }

    func target(of url: URL) -> LinkTarget? {
        guard let book, let id = ChapterRenderer.linkTarget(url) else { return nil }
        if url.scheme == ChapterRenderer.noteScheme, let note = book.notes[id] { return .note(note) }
        if let ordinal = book.idTargets[id] { return .block(ordinal) }
        return nil
    }

    // MARK: Search

    func search(_ query: String) async -> BookSearch.Result? {
        guard let book else { return nil }
        return await Task.detached(priority: .userInitiated) {
            BookSearch.search(query, in: book)
        }.value
    }

    func go(to hit: BookSearch.Hit) {
        guard let text = rendered(chapter: hit.chapterIndex)?.text,
              let display = text.utf16Range(of: hit.range) else { return }
        searchHighlight = ChapterRange(chapter: hit.chapterIndex, range: NSRange(location: display.lowerBound, length: display.count))
        show(chapter: hit.chapterIndex, at: hit.range.start, placement: .upperThird)
    }

    func clearSearchHighlight() {
        if searchHighlight != nil { searchHighlight = nil }
    }

    // MARK: Highlights

    func resolve(_ highlight: Highlight) -> LocatorResolution? {
        if let cached = resolutions[highlight.id], cached.json == highlight.locatorJSON { return cached.result }
        guard let service, let locator = highlight.locator else { return nil }
        let result = service.resolve(locator)
        resolutions[highlight.id] = (highlight.locatorJSON, result)
        return result
    }

    /// Decorations of one chapter: the user's highlights plus the current search result.
    func decorations(for highlights: [Highlight], chapter: Int) -> [HighlightDecoration] {
        guard let text = rendered(chapter: chapter)?.text else { return [] }
        var result = highlights.compactMap { highlight -> HighlightDecoration? in
            guard let range = resolve(highlight)?.range, let display = text.utf16Range(of: range) else { return nil }
            return HighlightDecoration(
                id: highlight.id,
                range: NSRange(location: display.lowerBound, length: display.count),
                color: highlight.color,
                hasNote: !highlight.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        if let hit = searchHighlight, hit.chapter == chapter {
            result.append(HighlightDecoration(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, range: hit.range, color: .azure, hasNote: false, kind: .searchHit))
        }
        return result
    }

    /// Decorations for the current chapter and its neighbours (page mode turns across chapters).
    func decorationsAroundCurrentChapter(for highlights: [Highlight]) -> [Int: [HighlightDecoration]] {
        var result: [Int: [HighlightDecoration]] = [:]
        for index in (chapterIndex - 1)...(chapterIndex + 1) where chapters.indices.contains(index) {
            result[index] = decorations(for: highlights, chapter: index)
        }
        return result
    }

    func unresolvedCount(in highlights: [Highlight]) -> Int {
        highlights.filter { resolve($0) == .notFound }.count
    }

    /// Creates a highlight for a display selection. Returns `nil` if it contains no text.
    func createHighlight(for selection: ChapterRange, color: HighlightColor, context: ModelContext) -> Highlight? {
        guard let rendered = rendered(chapter: selection.chapter), let service, let book else { return nil }
        let display = selection.range.location..<(selection.range.location + selection.range.length)
        guard let range = rendered.text.blockRange(forUTF16: display),
              let locator = service.locator(for: range),
              let json = try? locator.jsonString() else { return nil }
        let chapter = book.chapters[locator.chapter]
        let highlight = Highlight(
            bookFingerprint: storedBook.fingerprint,
            bookTitle: storedBook.title,
            bookAuthors: storedBook.authors,
            chapterIndex: chapter.index,
            chapterTitle: chapter.title,
            text: locator.quote?.exact ?? book.text(in: range),
            colorKey: color.rawValue,
            locatorJSON: json,
            progression: locator.progression
        )
        context.insert(highlight)
        try? context.save()
        resolutions[highlight.id] = (json, .exact(range))
        return highlight
    }
}

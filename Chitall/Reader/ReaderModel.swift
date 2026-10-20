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
    /// One paragraph at a time, larger, the next one by a tap or a swipe (DECISIONS.md §20).
    case paragraph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pages: return "Страницы"
        case .scroll: return "Прокрутка"
        case .paragraph: return "По абзацу"
        }
    }

    /// The paragraph mode sets its text this much larger than the chosen size.
    static let paragraphScale: Double = 1.25
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
        let chapter: Int
        let page: Int
        let pageCount: Int
    }

    let storedBook: StoredBook
    private(set) var phase: Phase = .loading
    private(set) var book: ReadableBook?
    private(set) var chapterIndex = 0
    /// Typography and theme of the page; changing it re-renders chapters on demand.
    private(set) var style = ReaderStyle(fontSize: 19, lineSpacing: 1.4)
    private(set) var navigation: NavigationRequest?
    private(set) var pageStatus: PageStatus?
    private(set) var searchHighlight: ChapterRange?
    /// Page counts of every chapter for the current page layout (computed in the background).
    private(set) var pageNumbering: PageNumbering?
    /// What is on screen now: the page in page mode, top to bottom of the screen in scroll mode.
    private(set) var visibleRange: ChapterRange?
    var chromeVisible = true
    /// Counts page turns and drags by the reader (not jumps): the view hides its panels and the
    /// "where I stopped" card when it changes.
    private(set) var userMoves = 0
    /// The reader's own reading speed (all books), for "≈ 6 мин до конца главы".
    private(set) var pace: ReadingPace
    /// The last words read before the saved place, shown once when the book reopens there.
    private(set) var resumeSnippet: String?
    /// "Напомнить о паузе": the current stretch of reading (the bottom panel shows what is left).
    private(set) var pauseTimer = PauseTimer()
    /// The query of the search sheet, kept while the book is open.
    @ObservationIgnored var lastSearchQuery = ""

    private let files: BookFileStore
    @ObservationIgnored private var service: LocatorService?
    @ObservationIgnored private var bookLanguage = "ru"
    @ObservationIgnored private var numberingTask: Task<Void, Never>?
    @ObservationIgnored private var numberingKey: String?
    @ObservationIgnored private var renderCache: [Int: RenderedChapter] = [:]
    @ObservationIgnored private var resolutions: [UUID: (json: String, result: LocatorResolution)] = [:]
    /// Display positions of bookmarks; display offsets do not depend on the typography.
    @ObservationIgnored private var bookmarkPositions: [UUID: (json: String, chapter: Int, offset: Int)] = [:]
    @ObservationIgnored private var chapterTexts: [Int: ChapterText] = [:]
    @ObservationIgnored private var lastPosition: (chapter: Int, utf16: Int)?
    @ObservationIgnored private var wordIndexes: [Int: WordIndex] = [:]
    @ObservationIgnored private var stepCache: [Int: ParagraphSteps] = [:]
    /// Where and when the current stretch of reading started (for the pace).
    @ObservationIgnored private var paceAnchor: (chapter: Int, offset: Int, time: Date)?
    @ObservationIgnored private let defaults: UserDefaults
    /// The clock, replaceable in tests.
    @ObservationIgnored var now: () -> Date = Date.init

    init(book: StoredBook, files: BookFileStore, defaults: UserDefaults = .standard) {
        self.storedBook = book
        self.files = files
        self.defaults = defaults
        self.pace = defaults.data(forKey: ReaderPreferences.paceKey)
            .flatMap { try? JSONDecoder().decode(ReadingPace.self, from: $0) } ?? ReadingPace()
    }

    var isReady: Bool { phase == .ready }

    var chapters: [Chapter] { book?.chapters ?? [] }

    var currentChapter: Chapter? {
        guard let book, book.chapters.indices.contains(chapterIndex) else { return nil }
        return book.chapters[chapterIndex]
    }

    var styleKey: String { style.key }

    /// The current chapter, rendered in the current typography.
    var rendered: RenderedChapter? {
        _ = style // re-render dependants when the typography changes
        return rendered(chapter: chapterIndex)
    }

    // MARK: Loading

    func load(style: ReaderStyle, initialHighlight: Highlight?) async {
        guard book == nil else { return }
        let fileName = storedBook.fileName
        let fingerprint = storedBook.fingerprint
        let files = self.files
        do {
            let parsed = try await Task.detached(priority: .userInitiated) { () throws -> ReadableBook in
                try FB2Parser.parse(files.readBook(named: fileName)).book
            }.value
            book = parsed
            service = LocatorService(book: parsed, fingerprint: fingerprint)
            bookLanguage = Self.hyphenationLanguage(parsed.metadata.language)
            self.style = withBookLanguage(style)

            if let initialHighlight, let range = resolve(initialHighlight)?.range,
               let chapter = parsed.chapterIndex(ofBlock: range.start.block) {
                show(chapter: chapter, at: range.start, placement: .upperThird)
            } else if let position = savedReadingPosition(), let chapter = parsed.chapterIndex(ofBlock: position.block) {
                show(chapter: chapter, at: position, placement: .top)
                resumeSnippet = ResumeSnippet.make(from: parsed.text(before: position, limit: 600))
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
        paceAnchor = nil // a jump is not reading
    }

    func showNextChapter() { show(chapter: chapterIndex + 1) }
    func showPreviousChapter() { show(chapter: chapterIndex - 1) }

    var hasNextChapter: Bool { chapterIndex + 1 < chapters.count }
    var hasPreviousChapter: Bool { chapterIndex > 0 }

    /// The progress slider: jump to a share of the whole book.
    func go(toProgression progression: Double) {
        guard let book, let position = book.position(atProgression: progression),
              let chapter = book.chapterIndex(ofBlock: position.block) else { return }
        clearSearchHighlight()
        show(chapter: chapter, at: position, placement: .top)
    }

    /// Chapter title at a share of the book, for the slider preview.
    func chapterTitle(atProgression progression: Double) -> String? {
        guard let book, let position = book.position(atProgression: progression),
              let chapter = book.chapterIndex(ofBlock: position.block) else { return nil }
        return book.chapters[chapter].title
    }

    /// Opens the place of a highlight (from the contents sheet).
    func go(to highlight: Highlight) {
        guard let range = resolve(highlight)?.range, let chapter = book?.chapterIndex(ofBlock: range.start.block) else { return }
        show(chapter: chapter, at: range.start, placement: .upperThird)
    }

    func go(toBlock ordinal: Int) {
        guard let chapter = book?.chapterIndex(ofBlock: ordinal) else { return }
        show(chapter: chapter, at: BlockPosition(block: ordinal, offset: 0), placement: .top)
    }

    /// Asks the active reading mode to show the last known position (after a mode switch).
    func navigateToCurrentPosition() {
        guard let position = lastPosition else { return }
        navigation = NavigationRequest(chapter: position.chapter, utf16Offset: position.utf16, placement: .top)
    }

    /// New typography or theme: cached chapters are re-rendered on demand; views keep their place.
    func restyle(_ newStyle: ReaderStyle) {
        let adjusted = withBookLanguage(newStyle)
        guard adjusted != style else { return }
        renderCache = [:]
        style = adjusted
    }

    private func withBookLanguage(_ style: ReaderStyle) -> ReaderStyle {
        var copy = style
        copy.language = bookLanguage
        return copy
    }

    /// FB2 `lang` such as "ru", "be", "ru-RU" → a language code TextKit can hyphenate.
    static func hyphenationLanguage(_ lang: String?) -> String {
        guard let lang, let code = lang.split(whereSeparator: { $0 == "-" || $0 == "_" }).first, !code.isEmpty else { return "ru" }
        return code.lowercased()
    }

    // MARK: Position reports from the views

    /// Page mode (and the paragraph mode, a paragraph being its page): the user turned to
    /// another page, possibly in another chapter.
    func didShowPage(chapter: Int, page: Int, pageCount: Int, firstOffset: Int, endOffset: Int) {
        if chapter != chapterIndex { chapterIndex = chapter }
        let status = PageStatus(chapter: chapter, page: page, pageCount: pageCount)
        if pageStatus != status { pageStatus = status }
        setVisible(chapter: chapter, from: firstOffset, to: endOffset)
        saveReadingPosition(chapter: chapter, atUTF16: firstOffset)
    }

    private func setVisible(chapter: Int, from start: Int, to end: Int) {
        let range = ChapterRange(chapter: chapter, range: NSRange(location: start, length: max(0, end - start)))
        if visibleRange != range { visibleRange = range }
        measurePace(chapter: chapter, offset: start)
    }

    // MARK: Reading pace, time left, the reader's own moves

    /// A page turn or a drag by the reader (not a jump from the contents or the slider).
    func userDidMove() {
        userMoves &+= 1
    }

    /// Starts a new stretch of reading for the pause reminder; 0 turns it off.
    func startPauseTimer(minutes: Int) {
        pauseTimer.start(minutes: minutes, at: now())
    }

    func dismissResume() {
        if resumeSnippet != nil { resumeSnippet = nil }
    }

    /// Words in a chapter from its start up to every offset (cached, cheap to query).
    func wordIndex(chapter: Int) -> WordIndex? {
        if let cached = wordIndexes[chapter] { return cached }
        guard let text = chapterText(chapter) else { return nil }
        let index = WordIndex(text.string)
        wordIndexes[chapter] = index
        return index
    }

    /// "≈ 6 мин до конца главы" from the top of the screen, at the reader's own pace.
    var chapterTimeLeft: String? {
        guard let visible = visibleRange, let index = wordIndex(chapter: visible.chapter) else { return nil }
        return pace.chapterLeftLabel(words: index.words(from: visible.range.location))
    }

    /// Reading forward in a chapter teaches the pace: words passed over the time it took.
    /// Jumps, skimming and pauses are rejected by `ReadingPace.record`.
    private func measurePace(chapter: Int, offset: Int) {
        let time = now()
        guard let anchor = paceAnchor, anchor.chapter == chapter, offset >= anchor.offset else {
            paceAnchor = (chapter, offset, time)
            return
        }
        guard let index = wordIndex(chapter: chapter) else { return }
        let words = index.words(in: anchor.offset..<offset)
        // Scrolling reports every line: wait for a stretch long enough to measure.
        guard words >= 40 || time.timeIntervalSince(anchor.time) > 600 else { return }
        if pace.record(words: words, seconds: time.timeIntervalSince(anchor.time)),
           let data = try? JSONEncoder().encode(pace) {
            defaults.set(data, forKey: ReaderPreferences.paceKey)
        }
        paceAnchor = (chapter, offset, time)
    }

    /// The end of the last chapter is on screen: only then the reader shows "100 %".
    var isAtEnd: Bool {
        guard let visible = visibleRange, visible.chapter == chapters.count - 1,
              let length = chapterText(visible.chapter)?.utf16Length else { return false }
        return NSMaxRange(visible.range) >= length
    }

    /// Whole percent of the book read, "100 %" only at the very end.
    var progressPercent: String {
        MaterialExport.wholePercent(storedBook.readingProgress, atEnd: isAtEnd)
    }

    /// The screens of the paragraph mode in a chapter (they do not depend on the typography).
    func paragraphSteps(chapter: Int) -> ParagraphSteps? {
        if let cached = stepCache[chapter] { return cached }
        guard let text = chapterText(chapter) else { return nil }
        let steps = ParagraphSteps(text)
        stepCache[chapter] = steps
        return steps
    }

    /// The character map of a chapter without rendering it (cheap, cached).
    private func chapterText(_ index: Int) -> ChapterText? {
        if let cached = renderCache[index] { return cached.text }
        if let cached = chapterTexts[index] { return cached }
        guard let book, book.chapters.indices.contains(index) else { return nil }
        let text = ChapterText(chapter: book.chapters[index])
        chapterTexts[index] = text
        return text
    }

    /// Paginates the whole book for a page layout off the main thread, so pages can show
    /// "118 из 294". Uses exactly the renderer and paginator the pages use.
    func requestPageNumbering(layoutKey: String, pageSize: CGSize) {
        guard let book, numberingKey != layoutKey, pageNumbering?.layoutKey != layoutKey else { return }
        numberingKey = layoutKey
        numberingTask?.cancel()
        let style = self.style
        numberingTask = Task.detached(priority: .utility) { [weak self] in
            var counts: [Int] = []
            for chapter in book.chapters {
                if Task.isCancelled { return }
                let attributed = ChapterRenderer.render(ChapterText(chapter: chapter), book: book, style: style)
                counts.append(Paginator.paginate(attributed, pageSize: pageSize).count)
            }
            let numbering = PageNumbering(layoutKey: layoutKey, counts: counts)
            await MainActor.run { [weak self] in
                guard let self, self.numberingKey == layoutKey else { return }
                self.pageNumbering = numbering
            }
        }
    }

    /// Continuous mode: the reader scrolled; `save` once scrolling has settled.
    func didScroll(chapter: Int, utf16Offset offset: Int, visibleEnd: Int, save: Bool) {
        if chapter != chapterIndex { chapterIndex = chapter }
        if pageStatus != nil { pageStatus = nil }
        setVisible(chapter: chapter, from: offset, to: visibleEnd)
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
    func createHighlight(for selection: ChapterRange, color: HighlightColor, tags: [String] = [], context: ModelContext) -> Highlight? {
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
        let tagNames = TagNames.normalizeAll(tags)
        if !tagNames.isEmpty {
            highlight.tags = tagNames
            for name in tagNames { TagCatalog.ensure(name, in: context) }
        }
        context.insert(highlight)
        try? context.save()
        resolutions[highlight.id] = (json, .exact(range))
        return highlight
    }

    // MARK: Bookmarks

    /// Chapter and display offset of a bookmark in the current book file (cached per locator).
    func position(of bookmark: Bookmark) -> (chapter: Int, offset: Int)? {
        let json = bookmark.locatorJSON
        if let cached = bookmarkPositions[bookmark.id], cached.json == json {
            return (cached.chapter, cached.offset)
        }
        guard let locator = try? Locator.fromJSONString(json), let service, let book,
              case let .caret(position) = service.resolve(locator),
              let chapter = book.chapterIndex(ofBlock: position.block),
              let offset = chapterText(chapter)?.utf16Offset(of: position) else { return nil }
        bookmarkPositions[bookmark.id] = (json: json, chapter: chapter, offset: offset)
        return (chapter, offset)
    }

    /// The bookmark on the page (or screen) the reader sees now, if any. In scroll mode the
    /// screen is the reader's current stretch of the tape: the icon fills while the bookmarked
    /// line is on screen and empties once it has scrolled away.
    func bookmarkOnScreen(in bookmarks: [Bookmark]) -> Bookmark? {
        guard let visible = visibleRange else { return nil }
        return bookmarks.first { bookmark in
            guard let position = position(of: bookmark), position.chapter == visible.chapter else { return false }
            return position.offset >= visible.range.location && position.offset <= NSMaxRange(visible.range)
        }
    }

    /// Bookmark offsets in every chapter (marks in the margin of the scroll tape).
    func bookmarkOffsets(_ bookmarks: [Bookmark]) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for bookmark in bookmarks {
            guard let position = position(of: bookmark) else { continue }
            result[position.chapter, default: []].append(position.offset)
        }
        return result
    }

    /// Adds a bookmark at the first line on screen, or removes the one already there.
    func toggleBookmark(in bookmarks: [Bookmark], context: ModelContext) {
        if let existing = bookmarkOnScreen(in: bookmarks) {
            context.delete(existing)
            try? context.save()
            return
        }
        guard let visible = visibleRange, let book, let service,
              let text = rendered(chapter: visible.chapter)?.text,
              let position = text.position(atUTF16: visible.range.location, forward: true),
              let locator = service.locator(at: position),
              let json = try? locator.jsonString() else { return }
        let snippet = book.text(after: position, limit: 100)
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        context.insert(Bookmark(
            bookFingerprint: storedBook.fingerprint,
            chapterIndex: visible.chapter,
            chapterTitle: book.chapters[visible.chapter].title,
            snippet: snippet,
            locatorJSON: json,
            progression: locator.progression
        ))
        try? context.save()
    }

    func go(to bookmark: Bookmark) {
        guard let position = position(of: bookmark) else { return }
        chapterIndex = position.chapter
        navigation = NavigationRequest(chapter: position.chapter, utf16Offset: position.offset, placement: .top)
        lastPosition = (position.chapter, position.offset)
        paceAnchor = nil
    }

    /// Bookmark offsets for the current chapter and its neighbours (ribbons on pages).
    func bookmarkOffsetsAroundCurrentChapter(_ bookmarks: [Bookmark]) -> [Int: [Int]] {
        var result: [Int: [Int]] = [:]
        for bookmark in bookmarks {
            guard let position = position(of: bookmark), abs(position.chapter - chapterIndex) <= 1 else { continue }
            result[position.chapter, default: []].append(position.offset)
        }
        return result
    }
}

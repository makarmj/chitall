import Foundation
import Observation
import SwiftData

struct ScrollRequest: Equatable {
    enum Placement: Equatable {
        /// The offset becomes the first visible line (reading position, chapter start).
        case top
        /// The offset lands in the upper third (a highlight opened from Materials).
        case upperThird
    }

    let id = UUID()
    let utf16Offset: Int
    let placement: Placement
}

struct HighlightDecoration: Equatable {
    let id: UUID
    let range: NSRange
    let color: HighlightColor
    let hasNote: Bool
}

/// State of an open book: the parsed model, the current chapter and the bridge between
/// display ranges, block positions and stored locators.
@MainActor
@Observable
final class ReaderModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let storedBook: StoredBook
    private(set) var phase: Phase = .loading
    private(set) var book: ReadableBook?
    private(set) var chapterIndex = 0
    private(set) var rendered: RenderedChapter?
    var scrollRequest: ScrollRequest?
    var findRequest: UUID?
    var chromeVisible = true

    private let files: BookFileStore
    @ObservationIgnored private var service: LocatorService?
    @ObservationIgnored private var style = ReaderStyle(fontSize: 19, lineSpacing: 1.35)
    @ObservationIgnored private var resolutions: [UUID: (json: String, result: LocatorResolution)] = [:]

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

    // MARK: Loading

    func load(style: ReaderStyle, initialHighlight: Highlight?) async {
        guard book == nil else { return }
        self.style = style
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

    // MARK: Chapters

    func show(chapter index: Int, at position: BlockPosition? = nil, placement: ScrollRequest.Placement = .top) {
        guard let book, book.chapters.indices.contains(index) else { return }
        chapterIndex = index
        let text = ChapterText(chapter: book.chapters[index])
        rendered = RenderedChapter(
            chapterIndex: index,
            styleKey: style.key,
            attributed: ChapterRenderer.render(text, book: book, style: style),
            text: text
        )
        let offset = position.flatMap { text.utf16Offset(of: $0) } ?? 0
        scrollRequest = ScrollRequest(utf16Offset: offset, placement: placement)
    }

    func showNextChapter() { show(chapter: chapterIndex + 1) }
    func showPreviousChapter() { show(chapter: chapterIndex - 1) }

    var hasNextChapter: Bool { chapterIndex + 1 < chapters.count }
    var hasPreviousChapter: Bool { chapterIndex > 0 }

    func go(toBlock ordinal: Int) {
        guard let chapter = book?.chapterIndex(ofBlock: ordinal) else { return }
        show(chapter: chapter, at: BlockPosition(block: ordinal, offset: 0), placement: .top)
    }

    /// Re-renders the current chapter in a new typography; the text view keeps its position.
    func restyle(_ newStyle: ReaderStyle) {
        guard newStyle != style else { return }
        style = newStyle
        guard let book, let rendered else { return }
        self.rendered = RenderedChapter(
            chapterIndex: rendered.chapterIndex,
            styleKey: newStyle.key,
            attributed: ChapterRenderer.render(rendered.text, book: book, style: newStyle),
            text: rendered.text
        )
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

    // MARK: Highlights

    func resolve(_ highlight: Highlight) -> LocatorResolution? {
        if let cached = resolutions[highlight.id], cached.json == highlight.locatorJSON { return cached.result }
        guard let service, let locator = highlight.locator else { return nil }
        let result = service.resolve(locator)
        resolutions[highlight.id] = (highlight.locatorJSON, result)
        return result
    }

    func decorations(for highlights: [Highlight]) -> [HighlightDecoration] {
        guard let rendered else { return [] }
        return highlights.compactMap { highlight in
            guard let range = resolve(highlight)?.range, let display = rendered.text.utf16Range(of: range) else { return nil }
            return HighlightDecoration(
                id: highlight.id,
                range: NSRange(location: display.lowerBound, length: display.count),
                color: highlight.color,
                hasNote: !highlight.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
    }

    func unresolvedCount(in highlights: [Highlight]) -> Int {
        highlights.filter { resolve($0) == .notFound }.count
    }

    /// Creates a highlight for a display selection. Returns `nil` if it contains no text.
    func createHighlight(for selection: NSRange, color: HighlightColor, context: ModelContext) -> Highlight? {
        guard let rendered, let service, let book else { return nil }
        let display = selection.location..<(selection.location + selection.length)
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

    // MARK: Reading position

    func saveReadingPosition(atUTF16 offset: Int) {
        guard let rendered, let service,
              let position = rendered.text.position(atUTF16: offset, forward: true),
              let locator = service.locator(at: position),
              let json = try? locator.jsonString() else { return }
        storedBook.readingPositionJSON = json
        storedBook.readingProgress = locator.progression
        storedBook.lastOpenedAt = .now
    }
}

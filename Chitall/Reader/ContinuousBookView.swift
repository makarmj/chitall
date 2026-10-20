import SwiftUI
import UIKit

/// Continuous reading mode: the whole book as one vertical scroll (DECISIONS.md §16).
///
/// Chapters are cut into chunks of about one and a half screens (the paginator with a tall
/// page) and shown as table rows with exactly measured heights. Only a few chapters around
/// the reader are loaded: the next one is appended while you approach the end, the previous
/// one is inserted above with the scroll offset compensated, so nothing jumps.
struct ContinuousBookView: UIViewControllerRepresentable {
    let model: ReaderModel
    var style: ReaderStyle
    var highlights: [Highlight]
    /// Changes whenever anything that affects decorations changes (colour, thought, search hit).
    var decorationsToken: Int
    /// Display offsets of bookmarks per chapter: ribbons in the margin of the tape.
    var bookmarks: [Int: [Int]]
    var navigation: NavigationRequest?
    var actions: ReaderTextActions
    /// Light up the paragraph at the reading line and dim the rest.
    var focusRuler = false

    func makeUIViewController(context: Context) -> ContinuousReaderController {
        ContinuousReaderController(model: model)
    }

    func updateUIViewController(_ controller: ContinuousReaderController, context: Context) {
        controller.actions = actions
        controller.focusRuler = focusRuler
        controller.update(style: style, highlights: highlights, decorationsToken: decorationsToken, navigation: navigation, bookmarks: bookmarks)
    }

    static func dismantleUIViewController(_ controller: ContinuousReaderController, coordinator: ()) {
        controller.reportPosition()
    }
}

final class ContinuousReaderController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    static let chunkHeight: CGFloat = 1400
    static let maximumLoadedChapters = 5

    var actions = ReaderTextActions()
    /// The focus ruler (DECISIONS.md §19): the paragraph crossing the reading line stays
    /// bright, at most five lines of it, the rest of the tape is dimmed.
    var focusRuler = false {
        didSet { if focusRuler != oldValue { updateFocus() } }
    }
    /// The reading line, as a share of the visible height from its top.
    static let readingLine: CGFloat = 0.3

    private struct LoadedChapter {
        let chapter: Int
        let ranges: [NSRange]
        let contents: [NSAttributedString]
        let heights: [CGFloat]

        var totalHeight: CGFloat { heights.reduce(0, +) }
    }

    private let model: ReaderModel
    let tableView = UITableView(frame: .zero, style: .plain)
    let focusDim = FocusDimView()
    private var loaded: [LoadedChapter] = []

    /// For tests: which chapters are in the scroll right now, and what is at the top.
    var loadedChapterIndices: [Int] { loaded.map(\.chapter) }
    var visiblePosition: (chapter: Int, offset: Int)? { currentPosition() }
    private var textWidth: CGFloat = 0
    private var style: ReaderStyle?
    private var highlights: [Highlight] = []
    private var decorationsToken = 0
    private var decorationCache: [Int: [HighlightDecoration]] = [:]
    private var bookmarks: [Int: [Int]] = [:]
    private var handledNavigation: UUID?
    private var pendingNavigation: NavigationRequest?
    private var isAdjusting = false
    /// The stretch of the tape last reported to the model (top line and bottom line).
    private var reportedVisible: (chapter: Int, start: Int, end: Int)?

    init(model: ReaderModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ContinuousReaderController is created in code")
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.separatorStyle = .none
        tableView.allowsSelection = false
        tableView.estimatedRowHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.contentInset = UIEdgeInsets(top: 52, left: 0, bottom: 72, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(ChunkCell.self, forCellReuseIdentifier: ChunkCell.reuseIdentifier)
        tableView.frame = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tableView)
        focusDim.frame = view.bounds
        focusDim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        focusDim.isUserInteractionEnabled = false // selection and taps go to the text below
        view.addSubview(focusDim)
        updateFocus()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let style else { return }
        defer { updateFocus() }
        let width = max(0, view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right - 2 * style.margins.points).rounded(.down)
        guard width > 1, width != textWidth else { return }
        // Width changed (first layout, rotation): cut the chapters again and stay on the same text.
        let anchor = currentPosition()
        textWidth = width
        if let pending = pendingNavigation {
            pendingNavigation = nil
            show(chapter: pending.chapter, offset: pending.utf16Offset, placement: pending.placement)
        } else if let anchor {
            show(chapter: anchor.chapter, offset: anchor.offset, placement: .top)
        }
    }

    // MARK: Updates from SwiftUI

    func update(style newStyle: ReaderStyle, highlights newHighlights: [Highlight], decorationsToken token: Int, navigation: NavigationRequest?, bookmarks newBookmarks: [Int: [Int]] = [:]) {
        highlights = newHighlights
        if newBookmarks != bookmarks {
            bookmarks = newBookmarks
            for case let cell as ChunkCell in tableView.visibleCells {
                cell.bookmarkOffsets = bookmarkOffsets(in: cell.fragment.chapter, range: cell.fragment.range)
            }
        }
        if token != decorationsToken {
            decorationsToken = token
            decorationCache = [:]
            refreshVisibleDecorations()
        }

        if newStyle != style {
            let anchor = currentPosition()
            let hadStyle = style != nil
            style = newStyle
            view.overrideUserInterfaceStyle = newStyle.theme.isDark ? .dark : .light
            view.backgroundColor = newStyle.colors.background
            tableView.backgroundColor = newStyle.colors.background
            tableView.indicatorStyle = newStyle.theme.isDark ? .white : .black
            // Margins change the text width; a width of 0 makes the next layout pass recompute it.
            let width = max(0, view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right - 2 * newStyle.margins.points).rounded(.down)
            textWidth = view.bounds.width > 1 ? width : 0
            decorationCache = [:]
            if hadStyle, textWidth > 1, let anchor, navigation?.id == handledNavigation || navigation == nil {
                show(chapter: anchor.chapter, offset: anchor.offset, placement: .top)
            }
            updateFocus()
        }

        if let navigation, navigation.id != handledNavigation {
            handledNavigation = navigation.id
            if textWidth < 1 {
                pendingNavigation = navigation // shown after the first layout
            } else {
                show(chapter: navigation.chapter, offset: navigation.utf16Offset, placement: navigation.placement)
            }
        }
    }

    // MARK: Chapters → chunks

    private func makeChapter(_ chapter: Int) -> LoadedChapter? {
        guard textWidth > 1, let rendered = model.rendered(chapter: chapter) else { return nil }
        let pages = Paginator.paginate(rendered.attributed, pageSize: CGSize(width: textWidth, height: Self.chunkHeight))
        var contents: [NSAttributedString] = []
        var heights: [CGFloat] = []
        for range in pages.ranges {
            let content = Paginator.chunkContent(of: rendered.attributed, range: range)
            contents.append(content)
            heights.append(max(1, TextMeasure.height(of: content, width: textWidth) + ChunkCell.verticalPadding))
        }
        return LoadedChapter(chapter: chapter, ranges: pages.ranges, contents: contents, heights: heights)
    }

    private func decorations(for chapter: Int) -> [HighlightDecoration] {
        if let cached = decorationCache[chapter] { return cached }
        let result = model.decorations(for: highlights, chapter: chapter)
        decorationCache[chapter] = result
        return result
    }

    private func bookmarkOffsets(in chapter: Int, range: NSRange) -> [Int] {
        (bookmarks[chapter] ?? []).filter { $0 >= range.location && $0 < NSMaxRange(range) }
    }

    private func row(at index: Int) -> (slot: Int, chunk: Int)? {
        var remaining = index
        for (slot, chapter) in loaded.enumerated() {
            if remaining < chapter.ranges.count { return (slot, remaining) }
            remaining -= chapter.ranges.count
        }
        return nil
    }

    private func firstRow(ofSlot slot: Int) -> Int {
        loaded.prefix(slot).reduce(0) { $0 + $1.ranges.count }
    }

    // MARK: Navigation

    private func show(chapter: Int, offset: Int, placement: NavigationRequest.Placement) {
        guard let target = makeChapter(chapter) else { return }
        isAdjusting = true
        loaded = [target]
        decorationCache = [:]
        tableView.reloadData()
        tableView.layoutIfNeeded()

        let chunk = ChapterPages(ranges: target.ranges).pageIndex(containing: offset)
        let rowTop = tableView.rectForRow(at: IndexPath(row: chunk, section: 0)).minY
        let local = max(0, offset - target.ranges[chunk].location)
        let lineTop = offset == 0 ? 0 : TextMeasure.y(ofOffset: local, in: target.contents[chunk], width: textWidth) + ChunkCell.topPadding
        let margin = placement == .upperThird ? tableView.bounds.height * 0.3 : 0
        scroll(toY: rowTop + lineTop - tableView.adjustedContentInset.top - margin)
        isAdjusting = false

        // Make room to scroll up right away, and report the new position.
        loadNeighboursIfNeeded()
        reportPosition()
        updateFocus()
    }

    private func scroll(toY y: CGFloat) {
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(minY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        tableView.setContentOffset(CGPoint(x: 0, y: min(max(y, minY), maxY)), animated: false)
    }

    // MARK: Loading neighbours

    private func loadNeighboursIfNeeded() {
        guard !isAdjusting, !loaded.isEmpty, tableView.bounds.height > 0 else { return }
        let y = tableView.contentOffset.y
        let height = tableView.bounds.height
        if y + height * 3 > tableView.contentSize.height { appendNextChapter() }
        if y < height * 2 { prependPreviousChapter() }
    }

    private func appendNextChapter() {
        guard let last = loaded.last, last.chapter + 1 < model.chapters.count,
              let next = makeChapter(last.chapter + 1) else { return }
        let firstNewRow = firstRow(ofSlot: loaded.count)
        loaded.append(next)
        let paths = (0..<next.ranges.count).map { IndexPath(row: firstNewRow + $0, section: 0) }
        UIView.performWithoutAnimation {
            tableView.insertRows(at: paths, with: .none)
        }
    }

    private func prependPreviousChapter() {
        guard let first = loaded.first, first.chapter > 0, let previous = makeChapter(first.chapter - 1) else { return }
        isAdjusting = true
        let offset = tableView.contentOffset
        loaded.insert(previous, at: 0)
        let paths = (0..<previous.ranges.count).map { IndexPath(row: $0, section: 0) }
        UIView.performWithoutAnimation {
            tableView.insertRows(at: paths, with: .none)
            tableView.layoutIfNeeded()
            // Everything below moved down by the inserted height: move the view with it.
            tableView.contentOffset = CGPoint(x: offset.x, y: offset.y + previous.totalHeight)
        }
        isAdjusting = false
    }

    /// Unloads chapters far from the reader once scrolling has settled.
    private func trimLoadedChapters() {
        guard loaded.count > Self.maximumLoadedChapters, let current = currentPosition()?.chapter else { return }
        isAdjusting = true
        while loaded.count > Self.maximumLoadedChapters {
            let first = loaded[0].chapter
            let last = loaded[loaded.count - 1].chapter
            if current - first >= last - current {
                let removed = loaded.removeFirst()
                let paths = (0..<removed.ranges.count).map { IndexPath(row: $0, section: 0) }
                let offset = tableView.contentOffset
                UIView.performWithoutAnimation {
                    tableView.deleteRows(at: paths, with: .none)
                    tableView.layoutIfNeeded()
                    tableView.contentOffset = CGPoint(x: offset.x, y: offset.y - removed.totalHeight)
                }
            } else {
                let firstRemovedRow = firstRow(ofSlot: loaded.count - 1)
                let removed = loaded.removeLast()
                let paths = (0..<removed.ranges.count).map { IndexPath(row: firstRemovedRow + $0, section: 0) }
                UIView.performWithoutAnimation {
                    tableView.deleteRows(at: paths, with: .none)
                }
            }
        }
        isAdjusting = false
    }

    // MARK: Position

    /// Chapter and offset of the first line under the top bar.
    private func currentPosition() -> (chapter: Int, offset: Int)? {
        position(atContentY: tableView.contentOffset.y + tableView.adjustedContentInset.top + 1)
    }

    /// Chapter and offset of the line at a content y (falls back to the nearest visible row).
    private func position(atContentY y: CGFloat) -> (chapter: Int, offset: Int)? {
        guard !loaded.isEmpty else { return nil }
        guard let indexPath = tableView.indexPathForRow(at: CGPoint(x: tableView.bounds.midX, y: y)) ?? tableView.indexPathsForVisibleRows?.first,
              let ref = row(at: indexPath.row) else { return nil }
        let chapter = loaded[ref.slot]
        if let cell = tableView.cellForRow(at: indexPath) as? ChunkCell {
            let inCell = tableView.convert(CGPoint(x: 0, y: y), to: cell).y
            return (chapter.chapter, cell.fragment.chapterOffset(atY: inCell))
        }
        return (chapter.chapter, chapter.ranges[ref.chunk].location)
    }

    /// End of what is visible, in the top line's chapter (for "is this screen bookmarked").
    private func visibleEnd(for top: (chapter: Int, offset: Int)) -> Int {
        // Scrolled to the very end of the book: everything up to the last character is seen.
        if let last = loaded.last, last.chapter == top.chapter, last.chapter == model.chapters.count - 1 {
            let maxY = tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            if tableView.contentOffset.y >= maxY - 2 { return NSMaxRange(last.ranges[last.ranges.count - 1]) }
        }
        let bottomY = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom - 1
        if let bottom = position(atContentY: bottomY), bottom.chapter == top.chapter, bottom.offset >= top.offset {
            return bottom.offset
        }
        let length = loaded.first { $0.chapter == top.chapter }.map { NSMaxRange($0.ranges[$0.ranges.count - 1]) } ?? top.offset
        return max(top.offset, length)
    }

    func reportPosition() {
        guard let position = currentPosition() else { return }
        let end = visibleEnd(for: position)
        reportedVisible = (chapter: position.chapter, start: position.offset, end: end)
        DispatchQueue.main.async { [weak model] in
            model?.didScroll(chapter: position.chapter, utf16Offset: position.offset, visibleEnd: end, save: true)
        }
    }

    /// While scrolling: tells the model what is on screen whenever the top or bottom line
    /// changes, so the bookmark icon and the chapter title follow the tape live.
    private func reportVisibleIfChanged() {
        guard let position = currentPosition() else { return }
        let end = visibleEnd(for: position)
        if let last = reportedVisible, last.chapter == position.chapter, last.start == position.offset, last.end == end { return }
        reportedVisible = (chapter: position.chapter, start: position.offset, end: end)
        DispatchQueue.main.async { [weak model] in
            model?.didScroll(chapter: position.chapter, utf16Offset: position.offset, visibleEnd: end, save: false)
        }
    }

    private func refreshVisibleDecorations() {
        for case let cell as ChunkCell in tableView.visibleCells {
            cell.fragment.apply(decorations: decorations(for: cell.fragment.chapter))
        }
    }

    // MARK: Focus ruler

    /// The bright band in view coordinates: the paragraph at the reading line, clipped to two
    /// lines above and below the line itself so a long paragraph still guides the eye.
    func focusBand() -> CGRect? {
        let insets = tableView.adjustedContentInset
        let readingY = insets.top + (tableView.bounds.height - insets.top - insets.bottom) * Self.readingLine
        let contentY = tableView.contentOffset.y + readingY
        guard let indexPath = tableView.indexPathForRow(at: CGPoint(x: tableView.bounds.midX, y: contentY)),
              let cell = tableView.cellForRow(at: indexPath) as? ChunkCell else { return nil }
        cell.layoutIfNeeded()
        let yInFragment = tableView.convert(CGPoint(x: 0, y: contentY), to: cell.fragment).y
        guard let lines = cell.fragment.focusLines(atY: yInFragment) else { return nil }
        let paragraph = cell.fragment.convert(lines.paragraph, to: view)
        let line = cell.fragment.convert(lines.line, to: view)
        let reach = line.height * 2
        let top = max(paragraph.minY, line.minY - reach)
        let bottom = min(paragraph.maxY, line.maxY + reach)
        guard bottom > top else { return nil }
        // A little air, so descenders and the line spacing are not cut.
        return CGRect(x: 0, y: top - 4, width: view.bounds.width, height: bottom - top + 8)
    }

    private func updateFocus() {
        guard isViewLoaded else { return }
        guard focusRuler, let style, !loaded.isEmpty else {
            focusDim.isHidden = true
            return
        }
        focusDim.isHidden = false
        focusDim.dimColor = style.colors.background.withAlphaComponent(style.theme.isDark ? 0.7 : 0.62)
        focusDim.band = focusBand()
    }

    private func setScrollEnabled(_ enabled: Bool) {
        tableView.isScrollEnabled = enabled
    }

    // MARK: UITableView

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        loaded.reduce(0) { $0 + $1.ranges.count }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let ref = row(at: indexPath.row) else { return 1 }
        return loaded[ref.slot].heights[ref.chunk]
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: ChunkCell.reuseIdentifier, for: indexPath)
        guard let chunkCell = cell as? ChunkCell, let ref = row(at: indexPath.row) else { return cell }
        let chapter = loaded[ref.slot]
        chunkCell.textWidth = textWidth
        if let style { chunkCell.apply(colors: style.colors) }
        chunkCell.fragment.actions = actions
        chunkCell.fragment.onSelectionChange = { [weak self] hasSelection in
            // While text is selected, a drag moves the selection handles, not the book.
            self?.setScrollEnabled(!hasSelection)
        }
        chunkCell.fragment.configure(
            chapter: chapter.chapter,
            range: chapter.ranges[ref.chunk],
            content: chapter.contents[ref.chunk],
            decorations: decorations(for: chapter.chapter)
        )
        chunkCell.bookmarkOffsets = bookmarkOffsets(in: chapter.chapter, range: chapter.ranges[ref.chunk])
        return chunkCell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isAdjusting else { return }
        loadNeighboursIfNeeded()
        reportVisibleIfChanged()
        updateFocus()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        model.userDidMove()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    private func settle() {
        trimLoadedChapters()
        reportPosition()
    }
}

/// Two translucent sheets in the theme's background colour above and below the focus band.
final class FocusDimView: UIView {
    private let above = UIView()
    private let below = UIView()

    var dimColor: UIColor = .clear {
        didSet {
            above.backgroundColor = dimColor
            below.backgroundColor = dimColor
        }
    }

    /// The bright band; `nil` dims nothing (no text under the reading line).
    var band: CGRect? {
        didSet { if band != oldValue { setNeedsLayout() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(above)
        addSubview(below)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FocusDimView is created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let band else {
            above.frame = .zero
            below.frame = .zero
            return
        }
        above.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, band.minY))
        below.frame = CGRect(x: 0, y: band.maxY, width: bounds.width, height: max(0, bounds.height - band.maxY))
    }

    /// The lit band as laid out (for tests).
    var litRange: ClosedRange<CGFloat>? {
        guard !isHidden, band != nil else { return nil }
        return above.frame.maxY...below.frame.minY
    }
}

/// A table row with one chunk of a chapter.
final class ChunkCell: UITableViewCell {
    static let reuseIdentifier = "ChunkCell"
    static let topPadding: CGFloat = 0
    static let verticalPadding: CGFloat = 2

    let fragment = TextFragmentView()
    /// The width the chunk was measured for; the text is laid out in exactly this width.
    var textWidth: CGFloat = 1 {
        didSet { setNeedsLayout() }
    }
    /// Chapter offsets of bookmarks inside this chunk: a ribbon in the right margin at each line.
    var bookmarkOffsets: [Int] = [] {
        didSet { if bookmarkOffsets != oldValue { setNeedsLayout() } }
    }
    private var ribbons: [UIImageView] = []
    private var ribbonColor: UIColor = .systemOrange

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.addSubview(fragment)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChunkCell is created in code")
    }

    func apply(colors: ThemeColors) {
        backgroundColor = colors.background
        contentView.backgroundColor = colors.background
        fragment.apply(colors: colors)
        ribbonColor = colors.accent
        for ribbon in ribbons { ribbon.tintColor = colors.accent }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fragment.frame = contentView.bounds
        // The table insets the content view to the safe area; centre the measured width in it.
        let left = ((contentView.bounds.width - textWidth) / 2).rounded(.down)
        fragment.textFrame = CGRect(x: left, y: Self.topPadding, width: textWidth, height: max(1, contentView.bounds.height - Self.topPadding))
        layoutRibbons()
    }

    /// Visible ribbon frames (for tests).
    var ribbonFrames: [CGRect] { ribbons.filter { !$0.isHidden }.map(\.frame) }

    private func layoutRibbons() {
        while ribbons.count < bookmarkOffsets.count {
            let ribbon = UIImageView(image: UIImage(systemName: "bookmark.fill"))
            ribbon.contentMode = .scaleAspectFit
            ribbon.tintColor = ribbonColor
            ribbon.isUserInteractionEnabled = false
            ribbon.accessibilityLabel = "Закладка"
            contentView.addSubview(ribbon)
            ribbons.append(ribbon)
        }
        fragment.layoutIfNeeded()
        let size = CGSize(width: 11, height: 15)
        let textFrame = fragment.textFrame
        let margin = contentView.bounds.width - textFrame.maxX
        let x = margin >= size.width + 4 ? textFrame.maxX + ((margin - size.width) / 2).rounded() : contentView.bounds.width - size.width - 1
        for (index, ribbon) in ribbons.enumerated() {
            guard index < bookmarkOffsets.count, let line = fragment.lineFrame(ofChapterOffset: bookmarkOffsets[index]) else {
                ribbon.isHidden = true
                continue
            }
            ribbon.isHidden = false
            ribbon.frame = CGRect(x: x, y: (line.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        }
    }
}

import SwiftUI
import UIKit

/// Page reading mode: the book as pages that turn with a swipe or a tap on the left/right
/// edge, continuing seamlessly from one chapter into the next (DECISIONS.md §15).
struct PagedBookView: UIViewControllerRepresentable {
    let model: ReaderModel
    var style: ReaderStyle
    var decorations: [Int: [HighlightDecoration]]
    var numbering: PageNumbering?
    /// Display offsets of bookmarks per chapter (around the current one).
    var bookmarks: [Int: [Int]]
    var navigation: NavigationRequest?
    var actions: ReaderTextActions

    func makeUIViewController(context: Context) -> PagedReaderController {
        PagedReaderController(model: model)
    }

    func updateUIViewController(_ controller: PagedReaderController, context: Context) {
        controller.actions = actions
        controller.update(style: style, decorations: decorations, numbering: numbering, bookmarks: bookmarks, navigation: navigation)
    }

    static func dismantleUIViewController(_ controller: PagedReaderController, coordinator: ()) {
        controller.reportCurrentPage()
    }
}

/// Where one page sits in the book.
struct PageLocation: Equatable {
    let chapter: Int
    let page: Int
}

final class PagedReaderController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var actions = ReaderTextActions()

    private let model: ReaderModel
    private let pager = UIPageViewController(
        transitionStyle: .scroll,
        navigationOrientation: .horizontal,
        options: [.interPageSpacing: 16]
    )
    private var layouts: [Int: ChapterPages] = [:]
    private var layoutKey = ""
    private var geometry: PageGeometry?
    private var style: ReaderStyle?
    private var decorations: [Int: [HighlightDecoration]] = [:]
    private var numbering: PageNumbering?
    private var bookmarks: [Int: [Int]] = [:]
    private var handledNavigation: UUID?
    private var pendingNavigation: NavigationRequest?

    init(model: ReaderModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PagedReaderController is created in code")
    }

    private var currentPage: PageViewController? {
        pager.viewControllers?.first as? PageViewController
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        pager.dataSource = self
        pager.delegate = self
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let style else { return }
        let newGeometry = PageGeometry(bounds: view.bounds, safeArea: view.safeAreaInsets, margin: style.margins.points)
        guard view.bounds.width > 1, newGeometry != geometry else { return }
        // Size changed (first layout, rotation): paginate again and stay on the same text.
        let anchor = currentPage.map { (chapter: $0.location.chapter, offset: $0.range.location) }
        geometry = newGeometry
        invalidateLayouts()
        model.requestPageNumbering(layoutKey: layoutKey, pageSize: newGeometry.textSize)
        if let pending = pendingNavigation {
            pendingNavigation = nil
            show(chapter: pending.chapter, offset: pending.utf16Offset)
        } else if let anchor {
            show(chapter: anchor.chapter, offset: anchor.offset)
        }
    }

    // MARK: Updates from SwiftUI

    func update(style newStyle: ReaderStyle, decorations newDecorations: [Int: [HighlightDecoration]], numbering newNumbering: PageNumbering?, bookmarks newBookmarks: [Int: [Int]], navigation: NavigationRequest?) {
        if newBookmarks != bookmarks {
            bookmarks = newBookmarks
            for case let page as PageViewController in pager.viewControllers ?? [] {
                page.isBookmarked = isBookmarked(page)
            }
        }

        if newStyle != style {
            let anchor = currentPage.map { (chapter: $0.location.chapter, offset: $0.range.location) }
            style = newStyle
            applyTheme(newStyle)
            // Margins change the page size: recompute it on the next layout pass.
            geometry = view.bounds.width > 1
                ? PageGeometry(bounds: view.bounds, safeArea: view.safeAreaInsets, margin: newStyle.margins.points)
                : nil
            invalidateLayouts()
            if let geometry { model.requestPageNumbering(layoutKey: layoutKey, pageSize: geometry.textSize) }
            if let anchor, geometry != nil, navigation?.id == handledNavigation || navigation == nil {
                show(chapter: anchor.chapter, offset: anchor.offset)
            }
        }

        if newNumbering != numbering {
            numbering = newNumbering
            for case let page as PageViewController in pager.viewControllers ?? [] {
                page.pageLabel = pageLabel(for: page.location, pageCount: page.pageCount)
            }
        }

        if newDecorations != decorations {
            decorations = newDecorations
            for case let page as PageViewController in pager.viewControllers ?? [] {
                page.apply(decorations: decorations[page.location.chapter] ?? [])
            }
        }

        if let navigation, navigation.id != handledNavigation {
            handledNavigation = navigation.id
            if geometry == nil {
                pendingNavigation = navigation // shown after the first layout
            } else {
                show(chapter: navigation.chapter, offset: navigation.utf16Offset)
            }
        }
    }

    private func applyTheme(_ style: ReaderStyle) {
        let colors = style.colors
        view.overrideUserInterfaceStyle = style.theme.isDark ? .dark : .light
        view.backgroundColor = colors.background
        pager.view.backgroundColor = colors.background
    }

    private func isBookmarked(_ page: PageViewController) -> Bool {
        (bookmarks[page.location.chapter] ?? []).contains { $0 >= page.range.location && $0 < NSMaxRange(page.range) }
    }

    /// "118 из 294" when the whole book is paginated for this layout, else "5 / 23" in the chapter.
    private func pageLabel(for location: PageLocation, pageCount: Int) -> String {
        if let numbering, numbering.layoutKey == layoutKey, let global = numbering.pageNumber(chapter: location.chapter, page: location.page) {
            return "\(global) из \(numbering.total)"
        }
        return "\(location.page + 1) / \(pageCount)"
    }

    private func invalidateLayouts() {
        layoutKey = "\(style?.key ?? "-")|\(geometry.map { "\($0.textSize.width)x\($0.textSize.height)" } ?? "-")"
        layouts = [:]
    }

    // MARK: Pages

    private func pages(for chapter: Int) -> ChapterPages? {
        if let cached = layouts[chapter] { return cached }
        guard let geometry, let rendered = model.rendered(chapter: chapter) else { return nil }
        let pages = Paginator.paginate(rendered.attributed, pageSize: geometry.textSize)
        if layouts.count >= 5, let farthest = layouts.keys.max(by: { abs($0 - chapter) < abs($1 - chapter) }) {
            layouts[farthest] = nil
        }
        layouts[chapter] = pages
        return pages
    }

    private func makePage(_ location: PageLocation) -> PageViewController? {
        guard let geometry, let style, let rendered = model.rendered(chapter: location.chapter),
              let pages = pages(for: location.chapter), pages.ranges.indices.contains(location.page) else { return nil }
        let range = pages.ranges[location.page]
        let page = PageViewController(
            location: location,
            range: range,
            pageCount: pages.count,
            chapterTitle: model.chapters[location.chapter].title,
            content: Paginator.pageContent(of: rendered.attributed, range: range),
            geometry: geometry,
            colors: style.colors
        )
        page.pageLabel = pageLabel(for: location, pageCount: pages.count)
        page.isBookmarked = isBookmarked(page)
        page.apply(decorations: decorations[location.chapter] ?? [])
        page.actions = actions
        page.onTurn = { [weak self] forward in self?.turn(forward: forward) }
        page.onSelectionChange = { [weak self] hasSelection in self?.setSwipeEnabled(!hasSelection) }
        return page
    }

    private func location(after location: PageLocation) -> PageLocation? {
        guard let pages = pages(for: location.chapter) else { return nil }
        if location.page + 1 < pages.count { return PageLocation(chapter: location.chapter, page: location.page + 1) }
        var chapter = location.chapter + 1
        while chapter < model.chapters.count {
            if let next = self.pages(for: chapter), next.count > 0 { return PageLocation(chapter: chapter, page: 0) }
            chapter += 1
        }
        return nil
    }

    private func location(before location: PageLocation) -> PageLocation? {
        if location.page > 0 { return PageLocation(chapter: location.chapter, page: location.page - 1) }
        var chapter = location.chapter - 1
        while chapter >= 0 {
            if let previous = pages(for: chapter), previous.count > 0 { return PageLocation(chapter: chapter, page: previous.count - 1) }
            chapter -= 1
        }
        return nil
    }

    private func show(chapter: Int, offset: Int) {
        guard let pages = pages(for: chapter) else { return }
        let location = PageLocation(chapter: chapter, page: pages.pageIndex(containing: offset))
        guard let page = makePage(location) else { return }
        pager.setViewControllers([page], direction: .forward, animated: false)
        reportCurrentPage()
    }

    private var isTurning = false
    /// Taps that arrive while a page is still sliding: +1 per "forward", −1 per "back".
    private var queuedTurns = 0

    private func turn(forward: Bool) {
        guard !isTurning else {
            // Remember quick successive taps instead of dropping them.
            queuedTurns = max(-3, min(3, queuedTurns + (forward ? 1 : -1)))
            return
        }
        guard let current = currentPage else { return }
        let target = forward ? location(after: current.location) : location(before: current.location)
        guard let target, let page = makePage(target) else {
            queuedTurns = 0
            return
        }
        isTurning = true
        pager.setViewControllers([page], direction: forward ? .forward : .reverse, animated: true) { [weak self] _ in
            guard let self else { return }
            self.isTurning = false
            self.reportCurrentPage()
            if self.queuedTurns != 0 {
                let next = self.queuedTurns > 0
                self.queuedTurns += next ? -1 : 1
                self.turn(forward: next)
            }
        }
    }

    private func setSwipeEnabled(_ enabled: Bool) {
        for case let scrollView as UIScrollView in pager.view.subviews {
            scrollView.isScrollEnabled = enabled
        }
    }

    /// Tells the model which page is on screen: saves the reading position and updates the bar.
    func reportCurrentPage() {
        guard let page = currentPage else { return }
        let location = page.location
        let firstOffset = page.range.location
        let endOffset = NSMaxRange(page.range)
        let count = page.pageCount
        DispatchQueue.main.async { [weak self, weak model] in
            model?.didShowPage(chapter: location.chapter, page: location.page, pageCount: count, firstOffset: firstOffset, endOffset: endOffset)
            self?.prefetchNeighbours(of: location, pageCount: count)
        }
    }

    /// Paginates the adjacent chapter ahead of time so that turning across a chapter boundary
    /// does not wait for layout.
    private func prefetchNeighbours(of location: PageLocation, pageCount: Int) {
        if location.page >= pageCount - 2, location.chapter + 1 < model.chapters.count {
            _ = pages(for: location.chapter + 1)
        }
        if location.page <= 1, location.chapter > 0 {
            _ = pages(for: location.chapter - 1)
        }
    }

    // MARK: UIPageViewController

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PageViewController, let target = location(before: page.location) else { return nil }
        return makePage(target)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? PageViewController, let target = location(after: page.location) else { return nil }
        return makePage(target)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        if completed { reportCurrentPage() }
    }
}

/// One page: a text fragment covering the whole page (so taps in the margins count), the
/// page's own small `UITextView`, a quiet chapter title above and the page number below.
final class PageViewController: UIViewController {
    let location: PageLocation
    /// The page's characters in chapter coordinates.
    let range: NSRange
    let pageCount: Int
    var actions = ReaderTextActions() {
        didSet { fragment.actions = actions }
    }
    var onTurn: (Bool) -> Void = { _ in } {
        didSet { fragment.onTurn = onTurn }
    }
    var onSelectionChange: (Bool) -> Void = { _ in } {
        didSet { fragment.onSelectionChange = onSelectionChange }
    }

    private let fragment = TextFragmentView()
    private let header = UILabel()
    private let footer = UILabel()
    private let content: NSAttributedString
    private let geometry: PageGeometry
    private let colors: ThemeColors
    private var decorations: [HighlightDecoration] = []
    /// "118 из 294" once the whole book is paginated, "5 / 23" (in the chapter) until then.
    var pageLabel = "" {
        didSet { footer.text = pageLabel }
    }
    var isBookmarked = false {
        didSet { ribbon.isHidden = !isBookmarked }
    }
    private let ribbon = UIImageView(image: UIImage(systemName: "bookmark.fill"))

    init(location: PageLocation, range: NSRange, pageCount: Int, chapterTitle: String, content: NSAttributedString, geometry: PageGeometry, colors: ThemeColors) {
        self.location = location
        self.range = range
        self.pageCount = pageCount
        self.content = content
        self.geometry = geometry
        self.colors = colors
        super.init(nibName: nil, bundle: nil)
        header.text = chapterTitle
        footer.text = "\(location.page + 1) / \(pageCount)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PageViewController is created in code")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = colors.background

        fragment.apply(colors: colors)
        fragment.turnZones = true
        fragment.actions = actions
        fragment.onTurn = onTurn
        fragment.onSelectionChange = onSelectionChange
        fragment.configure(chapter: location.chapter, range: range, content: content, decorations: decorations)
        fragment.textView.accessibilityHint = "Страница \(location.page + 1) из \(pageCount)"
        view.addSubview(fragment)

        for label in [header, footer] {
            label.font = UIFont.systemFont(ofSize: 12)
            label.textColor = colors.secondary
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.isAccessibilityElement = false
            label.isUserInteractionEnabled = false // taps on the title or page number still turn pages
            fragment.addSubview(label)
        }
        ribbon.tintColor = colors.accent
        ribbon.contentMode = .scaleAspectFit
        ribbon.isHidden = !isBookmarked
        ribbon.isUserInteractionEnabled = false
        ribbon.accessibilityLabel = "Закладка"
        fragment.addSubview(ribbon)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fragment.frame = view.bounds
        // Exactly the frame the paginator measured; a couple of points of slack against rounding.
        var frame = geometry.textFrame
        frame.size.height += 2
        fragment.textFrame = frame
        header.frame = CGRect(x: frame.minX, y: frame.minY - PageGeometry.headerHeight, width: frame.width, height: PageGeometry.headerHeight - 6)
        footer.frame = CGRect(x: frame.minX, y: geometry.textFrame.maxY + 6, width: frame.width, height: PageGeometry.footerHeight - 6)
        ribbon.frame = CGRect(x: view.bounds.width - 30, y: frame.minY - PageGeometry.headerHeight, width: 16, height: 22)
    }

    func apply(decorations newDecorations: [HighlightDecoration]) {
        decorations = newDecorations
        guard isViewLoaded else { return }
        fragment.apply(decorations: decorations)
    }
}

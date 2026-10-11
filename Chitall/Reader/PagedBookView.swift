import SwiftUI
import UIKit

/// Page reading mode: the book as pages that turn with a swipe or a tap on the left/right
/// edge, continuing seamlessly from one chapter into the next (DECISIONS.md §15).
struct PagedBookView: UIViewControllerRepresentable {
    let model: ReaderModel
    var styleKey: String
    var decorations: [Int: [HighlightDecoration]]
    var navigation: NavigationRequest?
    var actions: ReaderTextActions

    func makeUIViewController(context: Context) -> PagedReaderController {
        PagedReaderController(model: model)
    }

    func updateUIViewController(_ controller: PagedReaderController, context: Context) {
        controller.actions = actions
        controller.update(styleKey: styleKey, decorations: decorations, navigation: navigation)
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
    private var styleKey = ""
    private var decorations: [Int: [HighlightDecoration]] = [:]
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
        view.backgroundColor = Palette.backgroundUI
        pager.view.backgroundColor = Palette.backgroundUI
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
        let newGeometry = PageGeometry(bounds: view.bounds, safeArea: view.safeAreaInsets)
        guard view.bounds.width > 1, newGeometry != geometry else { return }
        // Size changed (first layout, rotation): paginate again and stay on the same text.
        let anchor = currentPage.map { (chapter: $0.location.chapter, offset: $0.range.location) }
        geometry = newGeometry
        invalidateLayouts()
        if let pending = pendingNavigation {
            pendingNavigation = nil
            show(chapter: pending.chapter, offset: pending.utf16Offset)
        } else if let anchor {
            show(chapter: anchor.chapter, offset: anchor.offset)
        }
    }

    // MARK: Updates from SwiftUI

    func update(styleKey newStyleKey: String, decorations newDecorations: [Int: [HighlightDecoration]], navigation: NavigationRequest?) {
        if newStyleKey != styleKey {
            let anchor = currentPage.map { (chapter: $0.location.chapter, offset: $0.range.location) }
            styleKey = newStyleKey
            invalidateLayouts()
            if let anchor, navigation?.id == handledNavigation || navigation == nil {
                show(chapter: anchor.chapter, offset: anchor.offset)
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

    private func invalidateLayouts() {
        layoutKey = "\(styleKey)|\(geometry.map { "\($0.textSize.width)x\($0.textSize.height)" } ?? "-")"
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
        guard let geometry, let rendered = model.rendered(chapter: location.chapter),
              let pages = pages(for: location.chapter), pages.ranges.indices.contains(location.page) else { return nil }
        let range = pages.ranges[location.page]
        let page = PageViewController(
            location: location,
            range: range,
            pageCount: pages.count,
            chapterTitle: model.chapters[location.chapter].title,
            content: Paginator.pageContent(of: rendered.attributed, range: range),
            geometry: geometry
        )
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

    private func turn(forward: Bool) {
        guard let current = currentPage else { return }
        let target = forward ? location(after: current.location) : location(before: current.location)
        guard let target, let page = makePage(target) else { return }
        view.isUserInteractionEnabled = false
        pager.setViewControllers([page], direction: forward ? .forward : .reverse, animated: true) { [weak self] _ in
            self?.view.isUserInteractionEnabled = true
            self?.reportCurrentPage()
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
        let count = page.pageCount
        DispatchQueue.main.async { [weak self, weak model] in
            model?.didShowPage(chapter: location.chapter, page: location.page, pageCount: count, firstOffset: firstOffset)
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

/// One page: its own small `UITextView` with just this page's characters, plus a quiet
/// chapter title above and the page number below.
final class PageViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    let location: PageLocation
    /// The page's characters in chapter coordinates.
    let range: NSRange
    let pageCount: Int
    var actions = ReaderTextActions()
    var onTurn: (Bool) -> Void = { _ in }
    var onSelectionChange: (Bool) -> Void = { _ in }

    private let textView = ReaderTextView(scrollable: false)
    private let header = UILabel()
    private let footer = UILabel()
    private let content: NSAttributedString
    private let geometry: PageGeometry
    private var decorations: [HighlightDecoration] = []

    /// Edge zones that turn pages; the middle toggles the reader controls.
    static let turnZoneFraction: CGFloat = 0.28

    init(location: PageLocation, range: NSRange, pageCount: Int, chapterTitle: String, content: NSAttributedString, geometry: PageGeometry) {
        self.location = location
        self.range = range
        self.pageCount = pageCount
        self.content = content
        self.geometry = geometry
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
        view.backgroundColor = Palette.backgroundUI

        for label in [header, footer] {
            label.font = UIFont.systemFont(ofSize: 12)
            label.textColor = Palette.secondaryInkUI
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.isAccessibilityElement = false
            view.addSubview(label)
        }

        textView.attributedText = content
        DecorationPainter.apply(decorations, to: textView.textStorage, chapterOffset: range.location)
        textView.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        textView.addGestureRecognizer(tap)
        view.addSubview(textView)

        textView.accessibilityHint = "Страница \(location.page + 1) из \(pageCount)"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Exactly the frame the paginator measured; a couple of points of slack against rounding.
        var frame = geometry.textFrame
        frame.size.height += 2
        textView.frame = frame
        header.frame = CGRect(x: frame.minX, y: frame.minY - PageGeometry.headerHeight, width: frame.width, height: PageGeometry.headerHeight - 6)
        footer.frame = CGRect(x: frame.minX, y: geometry.textFrame.maxY + 6, width: frame.width, height: PageGeometry.footerHeight - 6)
    }

    func apply(decorations newDecorations: [HighlightDecoration]) {
        decorations = newDecorations
        guard isViewLoaded else { return }
        DecorationPainter.apply(decorations, to: textView.textStorage, chapterOffset: range.location)
    }

    // MARK: Taps: edges turn pages, highlights open, the middle toggles controls

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard textView.selectedRange.length == 0 else { return } // the tap only dismisses a selection
        let local = textView.characterIndex(at: gesture.location(in: textView))
        // A footnote link opens through the text view's own link action, wherever it is.
        if let local, textView.textStorage.attribute(.link, at: local, effectiveRange: nil) != nil { return }

        let pointInPage = gesture.location(in: view)
        let zone = view.bounds.width * Self.turnZoneFraction
        if pointInPage.x < zone { onTurn(false); return }
        if pointInPage.x > view.bounds.width - zone { onTurn(true); return }

        guard let local else {
            actions.onTapText()
            return
        }
        if let decoration = DecorationPainter.highlight(at: local + range.location, in: decorations) {
            actions.onTapHighlight(decoration.id)
        } else {
            actions.onTapText()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard let tap = other as? UITapGestureRecognizer else { return false }
        return tap.numberOfTapsRequired > 1 && other.view === gestureRecognizer.view
    }

    // MARK: Selection, edit menu, links

    func textViewDidChangeSelection(_ textView: UITextView) {
        // While text is selected, a horizontal drag adjusts the selection instead of turning the page.
        onSelectionChange(textView.selectedRange.length > 0)
    }

    func textView(_ textView: UITextView, editMenuForTextIn localRange: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard localRange.length > 0 else { return nil }
        let selection = ChapterRange(
            chapter: location.chapter,
            range: NSRange(location: localRange.location + range.location, length: localRange.length)
        )
        return ReaderEditMenu.make(
            for: selection,
            decorations: decorations,
            suggestedActions: suggestedActions,
            perform: { [weak self] action in self?.actions.onSelectionAction(action) },
            clearSelection: { [weak textView] in textView?.selectedRange = NSRange(location: localRange.location, length: 0) }
        )
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        ReaderLinks.primaryAction(for: textItem, defaultAction: defaultAction) { [weak self] url in
            self?.actions.onTapLink(url)
        }
    }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        nil
    }
}

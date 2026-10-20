import SwiftUI
import UIKit

/// "По одному абзацу" (DECISIONS.md §20): only the current paragraph, larger, in the middle of
/// the screen; the next one by a tap at the right edge or a swipe left, the previous one at the
/// left edge or by a swipe right, on through the chapters. A screen is a `ParagraphSteps` range
/// in chapter coordinates, so the reading position, highlights, thoughts and bookmarks work
/// exactly as in the other modes. For days when it is especially hard to concentrate.
struct ParagraphBookView: UIViewControllerRepresentable {
    let model: ReaderModel
    var style: ReaderStyle
    var decorations: [Int: [HighlightDecoration]]
    /// Display offsets of bookmarks per chapter (around the current one).
    var bookmarks: [Int: [Int]]
    var navigation: NavigationRequest?
    var actions: ReaderTextActions
    /// "Чистый экран": no chapter title above the paragraph.
    var cleanScreen = false

    func makeUIViewController(context: Context) -> ParagraphReaderController {
        ParagraphReaderController(model: model)
    }

    func updateUIViewController(_ controller: ParagraphReaderController, context: Context) {
        controller.actions = actions
        controller.cleanScreen = cleanScreen
        controller.update(style: style, decorations: decorations, bookmarks: bookmarks, navigation: navigation)
    }

    static func dismantleUIViewController(_ controller: ParagraphReaderController, coordinator: ()) {
        controller.reportCurrent()
    }
}

final class ParagraphReaderController: UIViewController, UIGestureRecognizerDelegate {
    static let fadeDuration: TimeInterval = 0.18

    var actions = ReaderTextActions() {
        didSet { fragment.actions = actions }
    }
    var cleanScreen = false {
        didSet { header.isHidden = cleanScreen }
    }

    private let model: ReaderModel
    let scrollView = UIScrollView()
    let fragment = TextFragmentView()
    private let header = UILabel()
    private let footer = UILabel()
    private let ribbon = UIImageView(image: UIImage(systemName: "bookmark.fill"))
    private lazy var swipeForward = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
    private lazy var swipeBack = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))

    private var style: ReaderStyle?
    private var decorations: [Int: [HighlightDecoration]] = [:]
    private var bookmarks: [Int: [Int]] = [:]
    private var handledNavigation: UUID?
    private var pendingNavigation: NavigationRequest?
    /// The paragraph on screen: chapter and step.
    private(set) var location: PageLocation?
    /// Its characters in chapter coordinates (for tests and position reports).
    private(set) var shownRange: NSRange?
    private var stepCount = 0
    private var laidOutSize: CGSize = .zero

    init(model: ReaderModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ParagraphReaderController is created in code")
    }

    var isBookmarkShown: Bool { !ribbon.isHidden }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)

        fragment.turnZones = true
        fragment.actions = actions
        fragment.onTurn = { [weak self] forward in self?.turn(forward: forward) }
        fragment.onSelectionChange = { [weak self] hasSelection in
            // While text is selected, a drag moves the selection handles, not the book.
            self?.swipeForward.isEnabled = !hasSelection
            self?.swipeBack.isEnabled = !hasSelection
        }
        scrollView.addSubview(fragment)

        for label in [header, footer] {
            label.font = UIFont.systemFont(ofSize: 12)
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.isAccessibilityElement = false
            label.isUserInteractionEnabled = false
            view.addSubview(label)
        }
        header.isHidden = cleanScreen
        ribbon.contentMode = .scaleAspectFit
        ribbon.isHidden = true
        ribbon.isUserInteractionEnabled = false
        ribbon.accessibilityLabel = "Закладка"
        view.addSubview(ribbon)

        swipeForward.direction = .left
        swipeBack.direction = .right
        for swipe in [swipeForward, swipeBack] {
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        header.frame = CGRect(x: 24, y: safe.top + 4, width: max(0, view.bounds.width - 48), height: PageGeometry.headerHeight - 6)
        footer.frame = CGRect(x: 24, y: view.bounds.height - safe.bottom - PageGeometry.footerHeight + 6, width: max(0, view.bounds.width - 48), height: PageGeometry.footerHeight - 6)
        ribbon.frame = CGRect(x: view.bounds.width - 30, y: safe.top, width: 16, height: 22)
        guard style != nil, view.bounds.width > 1 else { return }
        if let pending = pendingNavigation {
            pendingNavigation = nil
            show(chapter: pending.chapter, offset: pending.utf16Offset)
        } else if view.bounds.size != laidOutSize {
            layoutParagraph()
        }
    }

    // MARK: Updates from SwiftUI

    func update(style newStyle: ReaderStyle, decorations newDecorations: [Int: [HighlightDecoration]], bookmarks newBookmarks: [Int: [Int]], navigation: NavigationRequest?) {
        if newBookmarks != bookmarks {
            bookmarks = newBookmarks
            updateRibbon()
        }
        if newStyle != style {
            style = newStyle
            let colors = newStyle.colors
            view.overrideUserInterfaceStyle = newStyle.theme.isDark ? .dark : .light
            view.backgroundColor = colors.background
            scrollView.backgroundColor = colors.background
            scrollView.indicatorStyle = newStyle.theme.isDark ? .white : .black
            fragment.apply(colors: colors)
            header.textColor = colors.secondary
            footer.textColor = colors.secondary
            ribbon.tintColor = colors.accent
            // Same paragraph, new typography.
            if let location, navigation?.id == handledNavigation || navigation == nil {
                display(location, report: false)
            }
        }
        if newDecorations != decorations {
            decorations = newDecorations
            if let location { fragment.apply(decorations: decorations[location.chapter] ?? []) }
        }
        if let navigation, navigation.id != handledNavigation {
            handledNavigation = navigation.id
            if view.bounds.width > 1 {
                show(chapter: navigation.chapter, offset: navigation.utf16Offset)
            } else {
                pendingNavigation = navigation // shown after the first layout
            }
        }
    }

    // MARK: Paragraphs

    private func show(chapter: Int, offset: Int) {
        guard let steps = model.paragraphSteps(chapter: chapter) else { return }
        if steps.count == 0 {
            // A chapter with nothing to read: the next one that has text.
            if let next = step(after: PageLocation(chapter: chapter, page: 0), skippingCurrent: false) { display(next) }
            return
        }
        display(PageLocation(chapter: chapter, page: steps.index(containing: offset)))
    }

    private func step(after current: PageLocation, skippingCurrent: Bool = true) -> PageLocation? {
        if skippingCurrent, let steps = model.paragraphSteps(chapter: current.chapter), current.page + 1 < steps.count {
            return PageLocation(chapter: current.chapter, page: current.page + 1)
        }
        var chapter = current.chapter + (skippingCurrent ? 1 : 0)
        while chapter < model.chapters.count {
            if let steps = model.paragraphSteps(chapter: chapter), steps.count > 0 { return PageLocation(chapter: chapter, page: 0) }
            chapter += 1
        }
        return nil
    }

    private func step(before current: PageLocation) -> PageLocation? {
        if current.page > 0 { return PageLocation(chapter: current.chapter, page: current.page - 1) }
        var chapter = current.chapter - 1
        while chapter >= 0 {
            if let steps = model.paragraphSteps(chapter: chapter), steps.count > 0 {
                return PageLocation(chapter: chapter, page: steps.count - 1)
            }
            chapter -= 1
        }
        return nil
    }

    /// The next (or previous) paragraph, on into the neighbouring chapter. A gentle cross-fade:
    /// no sliding page, nothing to follow with the eyes.
    func turn(forward: Bool) {
        guard let current = location,
              let target = forward ? step(after: current) : step(before: current) else { return }
        model.userDidMove()
        UIView.transition(with: scrollView, duration: Self.fadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.display(target)
        }
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended else { return }
        turn(forward: gesture.direction == .left)
    }

    private func display(_ target: PageLocation, report: Bool = true) {
        guard let style, let rendered = model.rendered(chapter: target.chapter),
              let steps = model.paragraphSteps(chapter: target.chapter), steps.ranges.indices.contains(target.page) else { return }
        let step = steps.ranges[target.page]
        let range = NSRange(location: step.lowerBound, length: step.count)
        location = target
        shownRange = range
        stepCount = steps.count
        fragment.apply(colors: style.colors)
        fragment.configure(
            chapter: target.chapter,
            range: range,
            content: Paginator.pageContent(of: rendered.attributed, range: range),
            decorations: decorations[target.chapter] ?? []
        )
        fragment.textView.accessibilityHint = "Абзац \(target.page + 1) из \(steps.count)"
        header.text = model.chapters[target.chapter].title
        footer.text = footerLabel()
        updateRibbon()
        layoutParagraph()
        scrollView.setContentOffset(.zero, animated: false)
        if report { reportCurrent() }
    }

    /// The paragraph a little above the middle; a paragraph taller than the screen scrolls.
    private func layoutParagraph() {
        guard let style, view.bounds.width > 1 else { return }
        laidOutSize = view.bounds.size
        let safe = view.safeAreaInsets
        let width = max(1, view.bounds.width - safe.left - safe.right - 2 * style.margins.points).rounded(.down)
        let height = TextMeasure.height(of: fragment.textView.attributedText ?? NSAttributedString(), width: width) + 2
        let top = safe.top + PageGeometry.headerHeight
        let bottom = safe.bottom + PageGeometry.footerHeight
        let room = view.bounds.height - top - bottom
        let y = height < room ? top + ((room - height) * 0.42).rounded() : top
        let contentHeight = max(view.bounds.height, y + height + bottom)
        fragment.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: contentHeight)
        fragment.textFrame = CGRect(x: safe.left + style.margins.points, y: y, width: width, height: height)
        scrollView.contentSize = CGSize(width: view.bounds.width, height: contentHeight)
    }

    /// "абзац 5 из 40 · ≈ 6 мин до конца главы".
    func footerLabel() -> String {
        guard let location, let range = shownRange else { return "" }
        var label = "абзац \(location.page + 1) из \(stepCount)"
        if let index = model.wordIndex(chapter: location.chapter),
           let left = model.pace.chapterLeftLabel(words: index.words(from: range.location)) {
            label += " · " + left
        }
        return label
    }

    private func updateRibbon() {
        guard let location, let range = shownRange else {
            ribbon.isHidden = true
            return
        }
        let marked = (bookmarks[location.chapter] ?? []).contains { $0 >= range.location && $0 <= NSMaxRange(range) }
        ribbon.isHidden = !marked
    }

    /// Tells the model which paragraph is on screen: saves the reading position, updates the bar.
    func reportCurrent() {
        guard let location, let range = shownRange else { return }
        let count = stepCount
        DispatchQueue.main.async { [weak model] in
            model?.didShowPage(chapter: location.chapter, page: location.page, pageCount: count, firstOffset: range.location, endOffset: NSMaxRange(range))
        }
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true // a swipe must not lose to the vertical scroll of a long paragraph
    }
}

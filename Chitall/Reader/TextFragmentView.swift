import UIKit

/// A piece of a chapter on screen: one page in page mode, one chunk of the continuous
/// scroll. The view covers the whole area that should react to taps (margins included);
/// the text itself sits at `textFrame` inside it.
///
/// Taps: with `turnZones` on, a tap in the left/right edge zone turns the page immediately
/// (no waiting for a double tap, which would select a word), a tap in the middle opens a
/// highlight or toggles the reader controls. Long press selection works everywhere.
final class TextFragmentView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate {
    /// Edge strips that turn pages, as in Yandex Books (about a quarter of the width each).
    static let turnZoneFraction: CGFloat = 0.25

    let textView = ReaderTextView()
    var actions = ReaderTextActions()
    var turnZones = false
    var onTurn: (Bool) -> Void = { _ in }
    var onSelectionChange: (Bool) -> Void = { _ in }
    var textFrame: CGRect = .zero {
        didSet { setNeedsLayout() }
    }

    private(set) var chapter = 0
    /// The fragment's characters in chapter coordinates.
    private(set) var range = NSRange(location: 0, length: 0)
    private var decorations: [HighlightDecoration] = []
    private lazy var edgeTap = UITapGestureRecognizer(target: self, action: #selector(handleEdgeTap(_:)))
    private lazy var centerTap = UITapGestureRecognizer(target: self, action: #selector(handleCenterTap(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.delegate = self
        addSubview(textView)
        for tap in [edgeTap, centerTap] {
            tap.delegate = self
            addGestureRecognizer(tap)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TextFragmentView is created in code")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = textFrame
    }

    func apply(colors: ThemeColors) {
        backgroundColor = colors.background
        textView.backgroundColor = colors.background
        textView.tintColor = colors.accent
        textView.linkTextAttributes = [.foregroundColor: colors.accent]
    }

    func configure(chapter: Int, range: NSRange, content: NSAttributedString, decorations: [HighlightDecoration]) {
        self.chapter = chapter
        self.range = range
        textView.selectedRange = NSRange(location: 0, length: 0)
        textView.attributedText = content
        apply(decorations: decorations)
    }

    func apply(decorations newDecorations: [HighlightDecoration]) {
        decorations = newDecorations
        DecorationPainter.apply(decorations, to: textView.textStorage, chapterOffset: range.location)
    }

    /// Chapter offset of the first character on the line at `y` (in this view's coordinates).
    func chapterOffset(atY y: CGFloat) -> Int {
        let local = textView.characterIndex(atY: y - textFrame.minY)
        return range.location + local
    }

    // MARK: Taps

    private func isInTurnZone(_ point: CGPoint) -> Bool {
        let zone = bounds.width * Self.turnZoneFraction
        return point.x < zone || point.x > bounds.width - zone
    }

    private func isOnLink(_ gesture: UIGestureRecognizer) -> Bool {
        guard let local = textView.characterIndex(at: gesture.location(in: textView)) else { return false }
        return textView.textStorage.attribute(.link, at: local, effectiveRange: nil) != nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = gestureRecognizer.location(in: self)
        if gestureRecognizer === edgeTap {
            // A tap with text selected only dismisses the selection; a footnote link opens itself.
            return turnZones && isInTurnZone(point) && textView.selectedRange.length == 0 && !isOnLink(gestureRecognizer)
        }
        if gestureRecognizer === centerTap {
            return !(turnZones && isInTurnZone(point)) && textView.selectedRange.length == 0 && !isOnLink(gestureRecognizer)
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        // In the middle a tap waits for the text view's double tap (word selection) to fail.
        guard gestureRecognizer === centerTap else { return false }
        return Self.isTextDoubleTap(other, in: textView)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // At the edges a quick second tap turns one more page instead of selecting a word.
        guard gestureRecognizer === edgeTap else { return false }
        return Self.isTextDoubleTap(other, in: textView)
    }

    private static func isTextDoubleTap(_ recognizer: UIGestureRecognizer, in textView: UITextView) -> Bool {
        guard let tap = recognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired > 1 else { return false }
        return tap.view === textView || tap.view?.isDescendant(of: textView) == true
    }

    @objc private func handleEdgeTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onTurn(gesture.location(in: self).x > bounds.width / 2)
    }

    @objc private func handleCenterTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if let local = textView.characterIndex(at: gesture.location(in: textView)),
           let decoration = DecorationPainter.highlight(at: local + range.location, in: decorations) {
            actions.onTapHighlight(decoration.id)
        } else {
            actions.onTapText()
        }
    }

    // MARK: Selection, edit menu, links

    func textViewDidChangeSelection(_ textView: UITextView) {
        onSelectionChange(textView.selectedRange.length > 0)
    }

    func textView(_ textView: UITextView, editMenuForTextIn localRange: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard localRange.length > 0 else { return nil }
        let selection = ChapterRange(
            chapter: chapter,
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
        nil // No link preview menu for internal chitall-note: URLs.
    }
}

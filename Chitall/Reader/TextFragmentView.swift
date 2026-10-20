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
    private lazy var linkTap = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.delegate = self
        addSubview(textView)
        for tap in [edgeTap, centerTap, linkTap] {
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

    /// The line that holds a chapter offset, in this view's coordinates (`nil` if outside).
    func lineFrame(ofChapterOffset offset: Int) -> CGRect? {
        let local = offset - range.location
        let storage = textView.textStorage
        guard storage.length > 0, local >= 0, local <= range.length else { return nil }
        let layoutManager = textView.layoutManager
        let glyph = layoutManager.glyphIndexForCharacter(at: min(local, storage.length - 1))
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.offsetBy(dx: textFrame.minX, dy: textFrame.minY)
    }

    /// For the focus ruler: the paragraph and the line at `y`, in this view's coordinates.
    func focusLines(atY y: CGFloat) -> (paragraph: CGRect, line: CGRect)? {
        let storage = textView.textStorage
        guard storage.length > 0 else { return nil }
        let layoutManager = textView.layoutManager
        let local = min(textView.characterIndex(atY: y - textFrame.minY), storage.length - 1)
        let paragraphRange = (storage.string as NSString).paragraphRange(for: NSRange(location: local, length: 0))
        let glyphs = layoutManager.glyphRange(forCharacterRange: paragraphRange, actualCharacterRange: nil)
        let paragraph = layoutManager.boundingRect(forGlyphRange: glyphs, in: textView.textContainer)
        let line = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: local), effectiveRange: nil)
        return (paragraph.offsetBy(dx: textFrame.minX, dy: textFrame.minY), line.offsetBy(dx: textFrame.minX, dy: textFrame.minY))
    }

    // MARK: Taps

    private func isInTurnZone(_ point: CGPoint) -> Bool {
        let zone = bounds.width * Self.turnZoneFraction
        return point.x < zone || point.x > bounds.width - zone
    }

    /// An internal link (footnote number, reference) under or right next to the touch.
    /// Superscript numbers are tiny, so a tap within a finger's width of one still opens it.
    private func link(near gesture: UIGestureRecognizer) -> URL? {
        let storage = textView.textStorage
        let layoutManager = textView.layoutManager
        guard storage.length > 0, layoutManager.numberOfGlyphs > 0 else { return nil }
        let point = gesture.location(in: textView)
        let glyph = layoutManager.glyphIndex(for: point, in: textView.textContainer)
        let first = max(0, glyph - 3)
        let last = min(layoutManager.numberOfGlyphs - 1, glyph + 3)
        for candidate in first...last {
            let character = layoutManager.characterIndexForGlyph(at: candidate)
            guard character < storage.length,
                  let url = storage.attribute(.link, at: character, effectiveRange: nil) as? URL,
                  ReaderLinks.isInternal(url) else { continue }
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: candidate, length: 1), in: textView.textContainer)
            if rect.insetBy(dx: -14, dy: -12).contains(point) { return url }
        }
        return nil
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let point = gestureRecognizer.location(in: self)
        // A tap with text selected only dismisses the selection; a footnote number opens its note.
        let idle = textView.selectedRange.length == 0
        if gestureRecognizer === linkTap {
            return idle && link(near: gestureRecognizer) != nil
        }
        if gestureRecognizer === edgeTap {
            return turnZones && isInTurnZone(point) && idle && link(near: gestureRecognizer) == nil
        }
        if gestureRecognizer === centerTap {
            return !(turnZones && isInTurnZone(point)) && idle && link(near: gestureRecognizer) == nil
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

    @objc private func handleLinkTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let url = link(near: gesture) else { return }
        actions.onTapLink(url)
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
        let selectedText = (textView.text as NSString?)
            .map { NSMaxRange(localRange) <= $0.length ? $0.substring(with: localRange) : "" } ?? ""
        return ReaderEditMenu.make(
            for: selection,
            selectedText: selectedText,
            decorations: decorations,
            quickTags: actions.quickTags,
            suggestedActions: suggestedActions,
            perform: { [weak self] action in self?.actions.onSelectionAction(action) },
            clearSelection: { [weak textView] in textView?.selectedRange = NSRange(location: localRange.location, length: 0) }
        )
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        ReaderLinks.primaryAction(for: textItem, defaultAction: defaultAction)
    }

    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        nil // No link preview menu for internal chitall-note: URLs.
    }
}

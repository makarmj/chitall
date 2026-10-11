import SwiftUI
import UIKit

/// Selection actions offered in the system edit menu.
enum SelectionAction {
    case highlight(NSRange, HighlightColor)
    case highlightWithThought(NSRange)
    case open(UUID)
}

/// Read-only, selectable chapter text. `UITextView` gives the system selection (handles,
/// magnifier, Copy, Look Up, Translate, Find) and exact `NSRange`s — see DECISIONS.md §1.
struct BookTextView: UIViewRepresentable {
    var content: RenderedChapter
    var decorations: [HighlightDecoration]
    var scrollRequest: ScrollRequest?
    var findRequest: UUID?
    var onSelectionAction: (SelectionAction) -> Void
    var onTapHighlight: (UUID) -> Void
    var onTapLink: (URL) -> Void
    var onTapText: () -> Void
    var onVisibleOffsetChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ReaderTextView {
        let view = ReaderTextView()
        view.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: ReaderTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view)
    }

    static func dismantleUIView(_ view: ReaderTextView, coordinator: Coordinator) {
        // Save the position once more when the reader closes, outside of the view update.
        guard view.textStorage.length > 0 else { return }
        let offset = view.firstVisibleOffset()
        let report = coordinator.parent.onVisibleOffsetChange
        DispatchQueue.main.async { report(offset) }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: BookTextView
        private var contentID: String?
        private var chapterIndex: Int?
        private var appliedDecorations: [HighlightDecoration] = []
        private var handledScrollRequest: UUID?
        private var handledFindRequest: UUID?

        init(parent: BookTextView) {
            self.parent = parent
        }

        // MARK: Updates from SwiftUI

        func update(_ view: ReaderTextView) {
            var offsetToKeep: Int?
            if parent.content.id != contentID {
                // Same chapter in a new typography: keep the first visible character in place.
                if contentID != nil, chapterIndex == parent.content.chapterIndex {
                    offsetToKeep = view.firstVisibleOffset()
                }
                view.attributedText = parent.content.attributed
                contentID = parent.content.id
                chapterIndex = parent.content.chapterIndex
                appliedDecorations = []
            }

            if parent.decorations != appliedDecorations {
                apply(parent.decorations, to: view)
                appliedDecorations = parent.decorations
            }

            if let request = parent.scrollRequest, request.id != handledScrollRequest {
                handledScrollRequest = request.id
                scheduleScroll(view, to: request.utf16Offset, placement: request.placement)
            } else if let offsetToKeep {
                scheduleScroll(view, to: offsetToKeep, placement: .top)
            }

            if let find = parent.findRequest, find != handledFindRequest {
                handledFindRequest = find
                view.findInteraction?.presentFindNavigator(showingReplace: false)
            }
        }

        private func apply(_ decorations: [HighlightDecoration], to view: ReaderTextView) {
            let storage = view.textStorage
            let whole = NSRange(location: 0, length: storage.length)
            guard whole.length > 0 else { return }
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: whole)
            storage.removeAttribute(.underlineStyle, range: whole)
            storage.removeAttribute(.underlineColor, range: whole)
            for decoration in decorations {
                let range = NSIntersectionRange(decoration.range, whole)
                guard range.length > 0 else { continue }
                storage.addAttribute(.backgroundColor, value: Palette.highlightBackgroundUI(decoration.color), range: range)
                if decoration.hasNote {
                    // A dotted underline marks highlights that carry a thought.
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, range: range)
                    storage.addAttribute(.underlineColor, value: Palette.solidUI(decoration.color), range: range)
                }
            }
            storage.endEditing()
        }

        private func scheduleScroll(_ view: ReaderTextView, to offset: Int, placement: ScrollRequest.Placement, attempt: Int = 0) {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                // SwiftUI may not have laid the view out yet on the very first update.
                if view.bounds.width < 1, attempt < 10 {
                    self.scheduleScroll(view, to: offset, placement: placement, attempt: attempt + 1)
                    return
                }
                view.scroll(toUTF16: offset, placement: placement)
            }
        }

        // MARK: Edit menu

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            let colorActions = HighlightColor.allCases.map { color in
                UIAction(title: color.displayName.capitalized, image: Swatch.image(for: color)) { [weak self, weak textView] _ in
                    self?.parent.onSelectionAction(.highlight(range, color))
                    textView?.selectedRange = NSRange(location: range.location, length: 0)
                }
            }
            var items: [UIMenuElement] = [
                UIMenu(title: "Выделить", image: UIImage(systemName: "highlighter"), children: colorActions),
                UIAction(title: "Мысль…", image: UIImage(systemName: "text.bubble")) { [weak self, weak textView] _ in
                    self?.parent.onSelectionAction(.highlightWithThought(range))
                    textView?.selectedRange = NSRange(location: range.location, length: 0)
                },
            ]
            if let existing = appliedDecorations.last(where: { NSIntersectionRange($0.range, range).length > 0 }) {
                items.append(UIAction(title: "Открыть выделение", image: UIImage(systemName: "bookmark")) { [weak self] _ in
                    self?.parent.onSelectionAction(.open(existing.id))
                })
            }
            // Our actions run their own handlers; the system ones (Copy, Look Up, Translate, Share) stay as is.
            return UIMenu(children: items + suggestedActions)
        }

        // MARK: Links (footnotes, internal references)

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            guard case let .link(url) = textItem.content else { return defaultAction }
            guard url.scheme == ChapterRenderer.noteScheme || url.scheme == ChapterRenderer.linkScheme else {
                return nil // Offline app: external links are not opened.
            }
            return UIAction { [weak self] _ in
                self?.parent.onTapLink(url)
            }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            nil // No link preview menu for internal chitall-note: URLs.
        }

        // MARK: Taps on highlights and on the page

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? ReaderTextView else { return }
            guard view.selectedRange.length == 0 else { return } // the tap only dismisses a selection
            guard let index = view.characterIndex(at: gesture.location(in: view)) else {
                parent.onTapText()
                return
            }
            if view.textStorage.attribute(.link, at: index, effectiveRange: nil) != nil { return }
            if let decoration = appliedDecorations.last(where: { NSLocationInRange(index, $0.range) }) {
                parent.onTapHighlight(decoration.id)
            } else {
                parent.onTapText()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            // Wait for the text view's double tap (word selection) to fail before treating a tap as ours.
            guard let tap = other as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired > 1 && other.view === gestureRecognizer.view
        }

        // MARK: Reading position

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { reportVisibleOffset(of: scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportVisibleOffset(of: scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            reportVisibleOffset(of: scrollView)
        }

        func reportVisibleOffset(of scrollView: UIScrollView) {
            guard let view = scrollView as? ReaderTextView, view.textStorage.length > 0 else { return }
            parent.onVisibleOffsetChange(view.firstVisibleOffset())
        }
    }
}

/// `UITextView` on an explicit TextKit 1 stack: stable full layout gives exact scrolling to a
/// stored position, which TextKit 2's estimated layout does not (DECISIONS.md §1).
final class ReaderTextView: UITextView {
    private let storage: NSTextStorage

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.storage = storage
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        alwaysBounceVertical = true
        dataDetectorTypes = []
        adjustsFontForContentSizeCategory = false
        backgroundColor = Palette.backgroundUI
        tintColor = Palette.accentUI
        linkTextAttributes = [.foregroundColor: Palette.accentUI]
        textContainerInset = UIEdgeInsets(top: 64, left: 22, bottom: 96, right: 22)
        textContainer.lineFragmentPadding = 0
        isFindInteractionEnabled = true
        keyboardDismissMode = .interactive
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReaderTextView is created in code")
    }

    /// Character offset (UTF-16) of the first line at the top of the visible area.
    func firstVisibleOffset() -> Int {
        guard textStorage.length > 0 else { return 0 }
        let y = contentOffset.y + adjustedContentInset.top - textContainerInset.top + 1
        let point = CGPoint(x: 1, y: max(0, y))
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        return min(layoutManager.characterIndexForGlyph(at: glyph), textStorage.length)
    }

    /// Character under a point, only if the point is really on a glyph (not in a margin).
    func characterIndex(at point: CGPoint) -> Int? {
        guard textStorage.length > 0 else { return nil }
        let location = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = layoutManager.glyphIndex(for: location, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -2, dy: -4).contains(location) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    func scroll(toUTF16 offset: Int, placement: ScrollRequest.Placement) {
        layoutIfNeeded()
        let length = textStorage.length
        guard length > 0 else { return }
        let target = max(0, min(offset, length - 1))
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: target, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let margin: CGFloat
        switch placement {
        case .top: margin = offset == 0 ? textContainerInset.top : 0
        case .upperThird: margin = bounds.height * 0.3
        }
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let y = rect.minY + textContainerInset.top - adjustedContentInset.top - margin
        setContentOffset(CGPoint(x: contentOffset.x, y: min(max(y, minY), maxY)), animated: false)
    }
}

enum Swatch {
    static func image(for color: HighlightColor, diameter: CGFloat = 18) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            Palette.solidUI(color).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
        }
        .withRenderingMode(.alwaysOriginal)
    }
}

import UIKit

/// A display range inside one chapter (UTF-16, chapter coordinates).
struct ChapterRange: Equatable {
    let chapter: Int
    let range: NSRange
}

/// Selection actions offered in the system edit menu.
enum SelectionAction {
    case highlight(ChapterRange, HighlightColor)
    case highlightWithThought(ChapterRange)
    case open(UUID)
}

/// Callbacks a text surface (the scrolling chapter or one page) sends to the reader screen.
struct ReaderTextActions {
    var onSelectionAction: (SelectionAction) -> Void = { _ in }
    var onTapHighlight: (UUID) -> Void = { _ in }
    var onTapLink: (URL) -> Void = { _ in }
    var onTapText: () -> Void = {}
}

/// Paints highlight decorations onto a text storage that shows the chapter from `offset` on.
enum DecorationPainter {
    static func apply(_ decorations: [HighlightDecoration], to storage: NSTextStorage, chapterOffset offset: Int) {
        let whole = NSRange(location: 0, length: storage.length)
        guard whole.length > 0 else { return }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: whole)
        storage.removeAttribute(.underlineStyle, range: whole)
        storage.removeAttribute(.underlineColor, range: whole)
        for decoration in decorations {
            let local = NSRange(location: decoration.range.location - offset, length: decoration.range.length)
            let range = NSIntersectionRange(local, whole)
            guard range.length > 0 else { continue }
            switch decoration.kind {
            case .highlight:
                storage.addAttribute(.backgroundColor, value: Palette.highlightBackgroundUI(decoration.color), range: range)
                if decoration.hasNote {
                    // A dotted underline marks highlights that carry a thought.
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, range: range)
                    storage.addAttribute(.underlineColor, value: Palette.solidUI(decoration.color), range: range)
                }
            case .searchHit:
                storage.addAttribute(.backgroundColor, value: Palette.searchHitUI, range: range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
                storage.addAttribute(.underlineColor, value: Palette.accentUI, range: range)
            }
        }
        storage.endEditing()
    }

    /// The highlight under a chapter offset, if any (search hits are not tappable).
    static func highlight(at chapterOffset: Int, in decorations: [HighlightDecoration]) -> HighlightDecoration? {
        decorations.last { $0.kind == .highlight && NSLocationInRange(chapterOffset, $0.range) }
    }
}

enum ReaderEditMenu {
    /// Our actions first, then the system ones (Copy, Look Up, Translate, Share) as provided.
    /// - Parameters:
    ///   - selection: the selected range in chapter coordinates.
    static func make(
        for selection: ChapterRange,
        decorations: [HighlightDecoration],
        suggestedActions: [UIMenuElement],
        perform: @escaping (SelectionAction) -> Void,
        clearSelection: @escaping () -> Void
    ) -> UIMenu {
        let colorActions = HighlightColor.allCases.map { color in
            UIAction(title: color.displayName.capitalized, image: Swatch.image(for: color)) { _ in
                perform(.highlight(selection, color))
                clearSelection()
            }
        }
        var items: [UIMenuElement] = [
            UIMenu(title: "Выделить", image: UIImage(systemName: "highlighter"), children: colorActions),
            UIAction(title: "Мысль…", image: UIImage(systemName: "text.bubble")) { _ in
                perform(.highlightWithThought(selection))
                clearSelection()
            },
        ]
        if let existing = decorations.last(where: { $0.kind == .highlight && NSIntersectionRange($0.range, selection.range).length > 0 }) {
            items.append(UIAction(title: "Открыть выделение", image: UIImage(systemName: "bookmark")) { _ in
                perform(.open(existing.id))
            })
        }
        return UIMenu(children: items + suggestedActions)
    }
}

enum ReaderLinks {
    /// Footnotes and internal references open inside the app; external links are not opened (offline app).
    static func primaryAction(for textItem: UITextItem, defaultAction: UIAction, onTapLink: @escaping (URL) -> Void) -> UIAction? {
        guard case let .link(url) = textItem.content else { return defaultAction }
        guard url.scheme == ChapterRenderer.noteScheme || url.scheme == ChapterRenderer.linkScheme else { return nil }
        return UIAction { _ in onTapLink(url) }
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

/// Fixed-size, non-scrolling `UITextView` on an explicit TextKit 1 stack (DECISIONS.md §1):
/// one page in page mode, one chunk in the continuous scroll.
final class ReaderTextView: UITextView {
    private let storage: NSTextStorage

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        self.storage = storage
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        textContainerInset = .zero
        clipsToBounds = true
        dataDetectorTypes = []
        adjustsFontForContentSizeCategory = false
        backgroundColor = Palette.backgroundUI
        tintColor = Palette.accentUI
        linkTextAttributes = [.foregroundColor: Palette.accentUI]
        isFindInteractionEnabled = false // the reader has its own whole-book search
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReaderTextView is created in code")
    }

    /// Character under a point, only if the point is really on a glyph (not in a margin).
    func characterIndex(at point: CGPoint) -> Int? {
        guard textStorage.length > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -2, dy: -4).contains(point) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// First character of the line at `y` (clamped to the text).
    func characterIndex(atY y: CGFloat) -> Int {
        guard textStorage.length > 0 else { return 0 }
        let glyph = layoutManager.glyphIndex(for: CGPoint(x: 1, y: max(0, y)), in: textContainer)
        var lineRange = NSRange(location: 0, length: 0)
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        return min(layoutManager.characterIndexForGlyph(at: lineRange.location), textStorage.length)
    }
}

/// Measuring text the way a `ReaderTextView` of a given width lays it out.
enum TextMeasure {
    /// Keeps the text storage alive for as long as its layout manager is used.
    struct Layout {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
    }

    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        let layout = layout(text, width: width)
        return ceil(layout.layoutManager.usedRect(for: layout.container).height)
    }

    /// Top of the line that contains `offset`.
    static func y(ofOffset offset: Int, in text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0 else { return 0 }
        let layout = layout(text, width: width)
        let character = max(0, min(offset, text.length - 1))
        let glyph = layout.layoutManager.glyphIndexForCharacter(at: character)
        return layout.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    static func layout(_ text: NSAttributedString, width: CGFloat) -> Layout {
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return Layout(storage: storage, layoutManager: layoutManager, container: container)
    }
}

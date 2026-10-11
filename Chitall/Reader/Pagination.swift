import UIKit

/// Page breaks of one chapter for one page size and typography.
///
/// TextKit 1 lays the chapter out through a chain of page-sized `NSTextContainer`s — the
/// layout manager decides where each page ends (DECISIONS.md §15). Each page is then shown by
/// its own ordinary `UITextView` holding just that page's characters, so pages never share
/// layout objects and a page's local offsets map back by adding `range.location`.
struct ChapterPages {
    /// Character (UTF-16) ranges in the chapter string; contiguous and covering all of it.
    let ranges: [NSRange]

    var count: Int { ranges.count }

    /// Index of the page that shows `offset`. Offsets past the end map to the last page.
    func pageIndex(containing offset: Int) -> Int {
        guard !ranges.isEmpty else { return 0 }
        var low = 0
        var high = ranges.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if ranges[middle].location <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

enum Paginator {
    static let maximumPages = 20_000

    static func paginate(_ attributed: NSAttributedString, pageSize: CGSize) -> ChapterPages {
        guard attributed.length > 0, pageSize.width > 1, pageSize.height > 1 else {
            return ChapterPages(ranges: [NSRange(location: 0, length: attributed.length)])
        }
        FittingImageAttachment.limit(in: attributed, toHeight: pageSize.height)

        let storage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let totalGlyphs = layoutManager.numberOfGlyphs

        var ranges: [NSRange] = []
        var nextCharacter = 0
        while nextCharacter < storage.length, ranges.count < maximumPages {
            let container = NSTextContainer(size: pageSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphs = layoutManager.glyphRange(for: container)
            guard glyphs.length > 0 else { break } // nothing fits: give the rest to the last page
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            ranges.append(NSRange(location: nextCharacter, length: NSMaxRange(characters) - nextCharacter))
            nextCharacter = NSMaxRange(characters)
            if NSMaxRange(glyphs) >= totalGlyphs { break }
        }

        if ranges.isEmpty {
            ranges = [NSRange(location: 0, length: storage.length)]
        } else if nextCharacter < storage.length, var last = ranges.popLast() {
            last.length = storage.length - last.location
            ranges.append(last)
        }
        return ChapterPages(ranges: ranges)
    }

    /// The characters of one page, ready for its own text view. A page that starts inside a
    /// paragraph continues it without a first-line indent; no page starts with extra spacing.
    static func pageContent(of chapter: NSAttributedString, range: NSRange) -> NSAttributedString {
        let page = NSMutableAttributedString(attributedString: chapter.attributedSubstring(from: range))
        guard page.length > 0 else { return page }
        let chapterText = chapter.string as NSString
        let startsInsideParagraph = range.location > 0 && chapterText.character(at: range.location - 1) != 0x0A

        let pageText = page.string as NSString
        let lineBreak = pageText.range(of: "\n")
        let firstParagraph = NSRange(location: 0, length: lineBreak.location == NSNotFound ? page.length : lineBreak.location + 1)
        if let style = page.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let adjusted = style.mutableCopy() as? NSMutableParagraphStyle {
            adjusted.paragraphSpacingBefore = 0
            if startsInsideParagraph { adjusted.firstLineHeadIndent = adjusted.headIndent }
            page.addAttribute(.paragraphStyle, value: adjusted, range: firstParagraph)
        }
        return page
    }
}

/// Where a page's text sits inside the screen. The paginator and the page view use the same
/// numbers, so the text laid out on screen is exactly the text measured for the page.
struct PageGeometry: Equatable {
    static let horizontalMargin: CGFloat = 24
    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 30

    let textFrame: CGRect

    init(bounds: CGRect, safeArea: UIEdgeInsets) {
        let top = safeArea.top + Self.headerHeight
        let bottom = safeArea.bottom + Self.footerHeight
        let left = max(safeArea.left, 0) + Self.horizontalMargin
        let right = max(safeArea.right, 0) + Self.horizontalMargin
        textFrame = CGRect(
            x: left,
            y: top,
            width: max(1, bounds.width - left - right),
            height: max(1, bounds.height - top - bottom)
        ).integral
    }

    var textSize: CGSize { textFrame.size }
}

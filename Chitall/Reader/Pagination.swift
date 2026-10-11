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

extension Paginator {
    /// The characters of one chunk of the continuous scroll. Like a page, but spacing before a
    /// paragraph is kept (the chunk border is invisible) and a trailing paragraph break is left
    /// out so that it does not add an empty line before the next chunk.
    static func chunkContent(of chapter: NSAttributedString, range: NSRange) -> NSAttributedString {
        var visible = range
        let chapterText = chapter.string as NSString
        if visible.length > 1, chapterText.character(at: NSMaxRange(visible) - 1) == 0x0A {
            visible.length -= 1
        }
        let chunk = NSMutableAttributedString(attributedString: chapter.attributedSubstring(from: visible))
        guard chunk.length > 0, visible.location > 0, chapterText.character(at: visible.location - 1) != 0x0A else {
            return chunk
        }
        let lineBreak = (chunk.string as NSString).range(of: "\n")
        let firstParagraph = NSRange(location: 0, length: lineBreak.location == NSNotFound ? chunk.length : lineBreak.location + 1)
        if let style = chunk.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let adjusted = style.mutableCopy() as? NSMutableParagraphStyle {
            adjusted.paragraphSpacingBefore = 0
            adjusted.firstLineHeadIndent = adjusted.headIndent
            chunk.addAttribute(.paragraphStyle, value: adjusted, range: firstParagraph)
        }
        return chunk
    }
}

/// Where a page's text sits inside the screen. The paginator and the page view use the same
/// numbers, so the text laid out on screen is exactly the text measured for the page.
struct PageGeometry: Equatable {
    static let headerHeight: CGFloat = 30
    static let footerHeight: CGFloat = 30

    let textFrame: CGRect

    init(bounds: CGRect, safeArea: UIEdgeInsets, margin: CGFloat = ReaderMargins.normal.points) {
        let top = safeArea.top + Self.headerHeight
        let bottom = safeArea.bottom + Self.footerHeight
        let left = max(safeArea.left, 0) + margin
        let right = max(safeArea.right, 0) + margin
        textFrame = CGRect(
            x: left,
            y: top,
            width: max(1, bounds.width - left - right),
            height: max(1, bounds.height - top - bottom)
        ).integral
    }

    var textSize: CGSize { textFrame.size }
}

/// Global page numbers: page counts of every chapter for one page layout.
struct PageNumbering: Equatable {
    let layoutKey: String
    let counts: [Int]
    private let firstPages: [Int]

    init(layoutKey: String, counts: [Int]) {
        self.layoutKey = layoutKey
        self.counts = counts
        var running = 0
        var firsts: [Int] = []
        for count in counts {
            firsts.append(running)
            running += count
        }
        self.firstPages = firsts
        self.total = running
    }

    let total: Int

    /// 1-based page number in the whole book.
    func pageNumber(chapter: Int, page: Int) -> Int? {
        guard firstPages.indices.contains(chapter), page < counts[chapter] else { return nil }
        return firstPages[chapter] + page + 1
    }
}

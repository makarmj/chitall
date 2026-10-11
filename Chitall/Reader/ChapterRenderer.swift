import UIKit

enum ReaderPreferences {
    static let themeKey = "app.theme"
    static let readerThemeKey = "reader.theme"
    static let fontKey = "reader.font"
    static let fontSizeKey = "reader.fontSize"
    static let spacingKey = "reader.spacing"
    static let marginsKey = "reader.margins"
    static let justifiedKey = "reader.justified"
    static let lastColorKey = "reader.lastHighlightColor"
    static let modeKey = "reader.mode"
    static let pageHintShownKey = "reader.pageHintShown"

    static let defaultFontSize: Double = 19
    static let fontSizeRange: ClosedRange<Double> = 14...32
}

/// One chapter ready for `UITextView`: the attributed string has exactly the characters of
/// `text.string`, so `ChapterText` maps every display offset back to a source position.
struct RenderedChapter {
    let chapterIndex: Int
    let styleKey: String
    let attributed: NSAttributedString
    let text: ChapterText

    var id: String { "\(chapterIndex)#\(styleKey)" }
}

enum ChapterRenderer {
    static let noteScheme = "chitall-note"
    static let linkScheme = "chitall-link"
    /// Language attribute TextKit uses for hyphenation (CoreText's kCTLanguageAttributeName).
    static let languageKey = NSAttributedString.Key("NSLanguage")

    static func render(_ text: ChapterText, book: ReadableBook, style: ReaderStyle) -> NSAttributedString {
        let size = style.fontSize
        let result = NSMutableAttributedString(string: text.string, attributes: [
            .font: style.font.font(size: size),
            .foregroundColor: style.colors.text,
            languageKey: style.language,
        ])

        var previous: Block?
        for (index, segment) in text.segments.enumerated() {
            let block = segment.block
            let isLast = index == text.segments.count - 1
            // Paragraph attributes cover the block and its trailing "\n".
            let paragraphRange = NSRange(location: segment.range.lowerBound, length: segment.range.count + (isLast ? 0 : 1))
            let look = BlockLook(block: block, previous: previous, style: style)
            if paragraphRange.length > 0 {
                result.addAttributes([
                    .paragraphStyle: look.paragraph,
                    .font: look.font,
                    .foregroundColor: look.color,
                ], range: paragraphRange)
            }

            for run in block.runs {
                let range = NSRange(location: segment.range.lowerBound + run.range.lowerBound, length: run.range.count)
                result.addAttributes(inlineAttributes(run, look: look, style: style), range: range)
            }

            if block.role == .image, segment.range.count == 1 {
                let range = NSRange(location: segment.range.lowerBound, length: 1)
                if let id = block.imageID, let image = book.images[id], let uiImage = UIImage(data: image.data) {
                    let attachment = FittingImageAttachment()
                    attachment.image = uiImage
                    result.addAttribute(.attachment, value: attachment, range: range)
                } else {
                    result.addAttribute(.foregroundColor, value: UIColor.clear, range: range)
                }
            }
            previous = block
        }
        return result
    }

    static func linkURL(_ target: String, isNote: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = isNote ? noteScheme : linkScheme
        components.path = target
        return components.url
    }

    static func linkTarget(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.path
    }

    private static func inlineAttributes(_ run: InlineRun, look: BlockLook, style: ReaderStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [:]
        var traits = look.traits
        if run.style.contains(.emphasis) { traits.insert(.traitItalic) }
        if run.style.contains(.strong) { traits.insert(.traitBold) }
        var size = look.size
        if run.style.contains(.superscript) || run.isNoteReference {
            size = look.size * 0.68
            attributes[.baselineOffset] = look.size * 0.33
        } else if run.style.contains(.subscript_) {
            size = look.size * 0.68
            attributes[.baselineOffset] = -look.size * 0.12
        }
        if run.style.contains(.code) {
            attributes[.font] = UIFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular)
        } else {
            attributes[.font] = style.font.font(size: size, weight: look.weight, traits: traits)
        }
        if run.style.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link, let url = linkURL(link, isNote: run.isNoteReference) {
            attributes[.link] = url
            attributes[.foregroundColor] = style.colors.accent
        }
        return attributes
    }
}

/// Typography of one block, derived from its role and context.
private struct BlockLook {
    let size: CGFloat
    let weight: UIFont.Weight
    let traits: UIFontDescriptor.SymbolicTraits
    let color: UIColor
    let paragraph: NSParagraphStyle
    let font: UIFont

    init(block: Block, previous: Block?, style: ReaderStyle) {
        let base = style.fontSize
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = base * 0.3
        // Body text: justified with hyphenation like a printed book, or ragged right.
        paragraph.alignment = style.justified ? .justified : .natural
        paragraph.hyphenationFactor = style.justified ? 0.9 : 0.3

        var size = base
        var weight: UIFont.Weight = .regular
        var traits: UIFontDescriptor.SymbolicTraits = []
        var color = style.colors.text

        switch block.role {
        case .title:
            size = base * (block.titleLevel == 0 ? 1.55 : block.titleLevel == 1 ? 1.4 : 1.18)
            weight = .semibold
            paragraph.alignment = .center
            paragraph.hyphenationFactor = 0
            paragraph.lineHeightMultiple = 1.1
            let startsTitle = previous?.role != .title
            paragraph.paragraphSpacingBefore = startsTitle && previous != nil ? base * 1.6 : 0
            paragraph.paragraphSpacing = base * 0.4
        case .subtitle:
            size = base * 1.05
            weight = .semibold
            paragraph.alignment = .center
            paragraph.hyphenationFactor = 0
            paragraph.paragraphSpacingBefore = base * 0.8
            paragraph.paragraphSpacing = base * 0.5
        case .verse:
            paragraph.alignment = .natural
            paragraph.hyphenationFactor = 0
            paragraph.firstLineHeadIndent = base * 2
            paragraph.headIndent = base * 3
            paragraph.paragraphSpacing = 0
            // A new stanza starts with its first verse: give it some air.
            if block.anchor.path.hasSuffix("/v[1]") { paragraph.paragraphSpacingBefore = base * 0.8 }
        case .textAuthor, .date:
            size = base * 0.9
            traits = .traitItalic
            color = style.colors.secondary
            paragraph.alignment = .right
            paragraph.hyphenationFactor = 0
            paragraph.paragraphSpacing = base * 0.6
        case .tableCell:
            size = base * 0.92
            paragraph.alignment = .natural
            paragraph.headIndent = base
            paragraph.firstLineHeadIndent = base
        case .image:
            paragraph.alignment = .center
            paragraph.paragraphSpacingBefore = base * 0.5
            paragraph.paragraphSpacing = base * 0.5
        case .emptyLine:
            paragraph.paragraphSpacing = 0
        case .paragraph:
            paragraph.firstLineHeadIndent = base * 1.5
        }

        if block.context.contains(.epigraph) {
            size = min(size, base * 0.92)
            if block.role == .paragraph {
                traits.insert(.traitItalic)
                paragraph.alignment = .natural
            }
            paragraph.headIndent = max(paragraph.headIndent, base * 5)
            paragraph.firstLineHeadIndent = max(paragraph.firstLineHeadIndent, base * 5)
        }
        if block.context.contains(.cite) {
            paragraph.headIndent = max(paragraph.headIndent, base * 1.5)
            paragraph.firstLineHeadIndent = max(paragraph.firstLineHeadIndent, base * 1.5)
            paragraph.tailIndent = -base
        }
        if block.context.contains(.annotation) {
            traits.insert(.traitItalic)
        }
        if block.context.contains(.notes), block.role != .title {
            size = min(size, base * 0.92)
        }

        self.size = size
        self.weight = weight
        self.traits = traits
        self.color = color
        self.paragraph = paragraph
        self.font = style.font.font(size: size, weight: weight, traits: traits)
    }
}

/// Scales embedded illustrations down to the text width and, in page mode, to the page height
/// (an image taller than a page could never be placed on one).
final class FittingImageAttachment: NSTextAttachment {
    var maxHeight: CGFloat = .greatestFiniteMagnitude

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> CGRect {
        guard let image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let maxWidth = max(1, lineFrag.width - 4)
        let scale = min(1, maxWidth / image.size.width, maxHeight / image.size.height)
        return CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
    }

    /// Caps every illustration in `text` to a fraction of the page height.
    static func limit(in text: NSAttributedString, toHeight pageHeight: CGFloat) {
        let cap = max(40, pageHeight * 0.85)
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            (value as? FittingImageAttachment)?.maxHeight = cap
        }
    }
}

import Foundation

/// One parsed content document of an EPUB spine.
struct XHTMLDocument {
    /// Path of the document inside the ZIP container, e.g. `OEBPS/Text/ch01.xhtml`.
    let resource: String
    let root: XMLNode
    let body: XMLNode
}

/// Resolves `href`/`src` values of a content document to container paths.
struct EPUBLinkResolver {
    /// Path inside the container of the document the reference is written in.
    let resource: String

    /// `ch02.xhtml#n5` → `OEBPS/Text/ch02.xhtml#n5`; `#n5` → `<resource>#n5`. `nil` for external
    /// links (`http:`, `mailto:` …): the app is offline and does not open them.
    func target(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !EPUBPath.hasScheme(trimmed) else { return nil }
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(parts[0])
        let fragment = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? String(parts[1])) : ""
        let path = pathPart.isEmpty ? resource : EPUBPath.resolve(pathPart, relativeTo: resource)
        return fragment.isEmpty ? path : path + "#" + fragment
    }

    func imagePath(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !EPUBPath.hasScheme(trimmed) else { return nil }
        let path = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return EPUBPath.resolve(String(path), relativeTo: resource)
    }
}

/// XHTML content documents → `Block`s of the shared reading model.
///
/// Every element is either skipped (`head`, scripts, EPUB 3 footnote asides), an image, a block
/// (HTML block-level elements) or inline. A block element whose children are all inline becomes
/// one paragraph anchored at the element itself (`/html/body[1]/div[2]/p[3]`). A block element
/// with block children is a container: its block children are visited in turn, and stretches of
/// inline content between them become paragraphs anchored at their first node, like stray text
/// in FB2 (`…/div[1]/text()[2]`). Paths and canonical text are what locators store
/// (docs/locator.md), so these rules are part of the format.
struct XHTMLBlockBuilder {
    static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "caption", "center", "dd", "details", "dialog",
        "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hgroup", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]
    static let skippedElements: Set<String> = ["head", "script", "style", "template", "noscript", "title"]
    static let noteTypes = ["footnote", "endnote", "rearnote", "note"]

    enum Kind {
        case skip
        case image
        case block
        case inline
    }

    private(set) var nextOrdinal: Int
    private(set) var idTargets: [String: Int] = [:]
    /// Container paths of images shown as blocks.
    private(set) var imagePaths: Set<String> = []
    /// Targets of note references (`resource#id`) → the label of the first reference, e.g. "3".
    private(set) var noteReferences: [String: String] = [:]
    private(set) var noteReferenceOrder: [String] = []

    private var blocks: [Block] = []
    private var resolver = EPUBLinkResolver(resource: "")
    /// The text of a note card leaves out its "back to the text" link (`↩`).
    private var skipsBacklinks = false

    init(firstOrdinal: Int = 0) {
        self.nextOrdinal = firstOrdinal
    }

    // MARK: Classification

    static func epubTypes(_ node: XMLNode) -> [String] {
        // `epub:type` arrives as `type` (prefixes are dropped); `role="doc-…"` is the ARIA form.
        let values = [node.attribute("type"), node.attribute("role")].compactMap { $0?.lowercased() }
        return values.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .map { $0.hasPrefix("doc-") ? String($0.dropFirst(4)) : $0 }
    }

    static func isFootnoteAside(_ node: XMLNode) -> Bool {
        node.name == "aside" && epubTypes(node).contains { noteTypes.contains($0) || $0 == "footnotes" }
    }

    static func kind(of node: XMLNode) -> Kind {
        if skippedElements.contains(node.name) || isFootnoteAside(node) { return .skip }
        if node.name == "img" || (node.name == "svg" && svgImage(node) != nil) || node.name == "image" { return .image }
        return blockElements.contains(node.name) ? .block : .inline
    }

    static func svgImage(_ node: XMLNode) -> XMLNode? {
        if node.name == "image" || node.name == "img" { return node }
        for child in node.elements {
            if let found = svgImage(child) { return found }
        }
        return nil
    }

    static func imageSource(_ node: XMLNode) -> String? {
        guard let image = node.name == "svg" ? svgImage(node) : node else { return nil }
        return image.attribute("src") ?? image.attribute("href")
    }

    // MARK: Building

    /// Blocks of one content document in document order, ordinals continuing the book's.
    mutating func build(_ document: XHTMLDocument) -> [Block] {
        blocks = []
        resolver = EPUBLinkResolver(resource: document.resource)
        visitContainer(document.body, context: blockContext(of: document.body, inherited: []))
        return blocks
    }

    /// Blocks of a single element (used to read the text of a note); ordinals are throwaway.
    mutating func buildFragment(_ node: XMLNode, resource: String) -> [Block] {
        blocks = []
        resolver = EPUBLinkResolver(resource: resource)
        skipsBacklinks = true
        defer { skipsBacklinks = false }
        let fragmentContext = blockContext(of: node, inherited: [])
        if Self.kind(of: node) == .block || node.name == "aside" {
            visitBlock(node, context: fragmentContext)
        } else {
            appendParagraph(anchorPath: node.path, children: [.element(node)], role: .paragraph, context: fragmentContext)
        }
        return blocks
    }

    private func blockContext(of node: XMLNode, inherited: BlockContext) -> BlockContext {
        var context = inherited
        let types = Self.epubTypes(node)
        let classes = (node.attribute("class") ?? "").lowercased()
        if node.name == "blockquote" { context.insert(.cite) }
        if node.name == "table" { context.insert(.table) }
        if types.contains("epigraph") || classes.contains("epigraph") { context.insert(.epigraph) }
        if ["poem", "poetry", "stanza", "verse"].contains(where: classes.contains) { context.insert(.poem) }
        if types.contains(where: { ["footnotes", "endnotes", "rearnotes", "footnote", "endnote", "rearnote"].contains($0) }) {
            context.insert(.notes)
        }
        return context
    }

    private mutating func registerID(_ node: XMLNode) {
        guard let id = node.attribute("id"), !id.isEmpty else { return }
        let key = resolver.resource + "#" + id
        if idTargets[key] == nil { idTargets[key] = nextOrdinal }
    }

    /// Block children make a container. Images do too, unless the element also has text: then
    /// they are inline pictures (not shown, see PROGRESS.md) and the paragraph stays whole.
    private func hasBlockChildren(_ node: XMLNode) -> Bool {
        var hasImage = false
        for child in node.elements {
            switch Self.kind(of: child) {
            case .block: return true
            case .image: hasImage = true
            case .skip, .inline: break
            }
        }
        return hasImage && !Self.hasVisibleText(node)
    }

    static func hasVisibleText(_ node: XMLNode) -> Bool {
        node.rawText.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{00A0}" }
    }

    private mutating func visitBlock(_ node: XMLNode, context inherited: BlockContext) {
        let context = blockContext(of: node, inherited: inherited)
        registerID(node)
        if node.name == "hr" {
            appendBlock(Block(ordinal: nextOrdinal, anchor: anchor(node.path), role: .emptyLine, context: context, text: ""))
            return
        }
        if hasBlockChildren(node) {
            visitContainer(node, context: context)
        } else {
            appendParagraph(anchorPath: node.path, children: node.children, role: role(of: node, context: context), context: context)
        }
    }

    private mutating func visitContainer(_ node: XMLNode, context: BlockContext) {
        var run: [XMLNode.Child] = []
        for child in node.children {
            guard case let .element(element) = child else {
                run.append(child)
                continue
            }
            switch Self.kind(of: element) {
            case .skip:
                // A footnote shown on tap only; links to it land next to where it stood.
                registerID(element)
            case .image:
                flushRun(&run, context: context)
                registerID(element)
                appendImage(element, context: context)
            case .block:
                flushRun(&run, context: context)
                visitBlock(element, context: context)
            case .inline:
                run.append(child)
            }
        }
        flushRun(&run, context: context)
    }

    /// Inline content between blocks of a container: a paragraph anchored at its first node.
    private mutating func flushRun(_ run: inout [XMLNode.Child], context: BlockContext) {
        defer { run = [] }
        let first = run.first { child in
            if case let .text(text, _) = child { return text.contains { !$0.isWhitespace } }
            return true
        }
        guard let first else { return }
        let path: String
        switch first {
        case let .text(_, textPath): path = textPath
        case let .element(element): path = element.path
        }
        appendParagraph(anchorPath: path, children: run, role: context.contains(.poem) ? .verse : .paragraph, context: context)
    }

    private func role(of node: XMLNode, context: BlockContext) -> BlockRole {
        switch node.name {
        case "h1", "h2", "h3", "h4", "h5", "h6": return .title
        case "td", "th": return .tableCell
        default: return context.contains(.poem) ? .verse : .paragraph
        }
    }

    private mutating func appendParagraph(anchorPath: String, children: [XMLNode.Child], role: BlockRole, context: BlockContext) {
        var segments: [TextCanonicalizer.Segment] = []
        var images: [XMLNode] = []
        var ids: [XMLNode] = []
        for child in children {
            collectInline(child, style: [], link: nil, isNote: false, into: &segments, images: &images, ids: &ids)
        }
        for node in ids { registerID(node) }
        let canonical = TextCanonicalizer.canonicalize(segments, keepsLineBreaks: true)

        if canonical.text.unicodeScalars.allSatisfy({ $0 == "\u{00A0}" || $0 == "\u{2028}" }) {
            if !images.isEmpty {
                for image in images { appendImage(image, context: context) }
            } else if !canonical.text.isEmpty {
                // `<p>&nbsp;</p>`: a spacer, as FB2's empty-line.
                appendBlock(Block(ordinal: nextOrdinal, anchor: anchor(anchorPath), role: .emptyLine, context: context, text: ""))
            }
            return
        }
        let level = role == .title ? titleLevel(ofPath: anchorPath) : 0
        appendBlock(Block(
            ordinal: nextOrdinal,
            anchor: anchor(anchorPath),
            role: role,
            context: context,
            titleLevel: level,
            text: canonical.text,
            runs: canonical.runs,
            elementID: nil
        ))
    }

    private func titleLevel(ofPath path: String) -> Int {
        // `/html/body[1]/h2[1]` → 2.
        guard let last = path.split(separator: "/").last, last.count >= 2, last.first == "h",
              let level = last.dropFirst().first.flatMap({ Int(String($0)) }) else { return 1 }
        return level
    }

    private mutating func appendImage(_ node: XMLNode, context: BlockContext) {
        guard let source = Self.imageSource(node), let path = resolver.imagePath(source) else { return }
        imagePaths.insert(path)
        let imageNode = node.name == "svg" ? (Self.svgImage(node) ?? node) : node
        appendBlock(Block(
            ordinal: nextOrdinal,
            anchor: anchor(imageNode.path),
            role: .image,
            context: context,
            text: "",
            elementID: node.attribute("id"),
            imageID: path
        ))
    }

    private func anchor(_ path: String) -> TextAnchor {
        TextAnchor(resource: resolver.resource, path: path)
    }

    private mutating func appendBlock(_ block: Block) {
        blocks.append(block)
        nextOrdinal += 1
    }

    // MARK: Inline content

    private mutating func collectInline(
        _ child: XMLNode.Child,
        style: InlineStyle,
        link: String?,
        isNote: Bool,
        into segments: inout [TextCanonicalizer.Segment],
        images: inout [XMLNode],
        ids: inout [XMLNode]
    ) {
        let element: XMLNode
        switch child {
        case let .text(text, _):
            segments.append(.init(text: text, style: style, link: link, isNoteReference: isNote))
            return
        case let .element(node):
            element = node
        }
        switch Self.kind(of: element) {
        case .skip:
            ids.append(element)
            return
        case .image:
            images.append(element)
            return
        case .block, .inline:
            break
        }
        if element.attribute("id") != nil { ids.append(element) }

        var nextStyle = style
        var nextLink = link
        var nextIsNote = isNote
        switch element.name {
        case "br":
            segments.append(.init(text: "\u{2028}", style: style, link: link, isNoteReference: isNote))
            return
        case "em", "i", "cite", "dfn", "var": nextStyle.insert(.emphasis)
        case "strong", "b": nextStyle.insert(.strong)
        case "s", "strike", "del": nextStyle.insert(.strikethrough)
        case "sub": nextStyle.insert(.subscript_)
        case "sup": nextStyle.insert(.superscript)
        case "code", "kbd", "samp", "tt": nextStyle.insert(.code)
        case "a" where skipsBacklinks && Self.epubTypes(element).contains("backlink"):
            return
        case "a":
            if let href = element.attribute("href"), let target = resolver.target(href) {
                nextLink = target
                nextIsNote = Self.isNoteReference(element, target: target, insideSuperscript: style.contains(.superscript))
                if nextIsNote, noteReferences[target] == nil {
                    noteReferences[target] = Self.noteLabel(element)
                    noteReferenceOrder.append(target)
                }
            }
        default:
            break
        }
        if let css = element.attribute("style")?.lowercased().replacingOccurrences(of: " ", with: "") {
            if css.contains("font-style:italic") || css.contains("font-style:oblique") { nextStyle.insert(.emphasis) }
            if css.contains("font-weight:bold") || ["600", "700", "800", "900"].contains(where: { css.contains("font-weight:" + $0) }) {
                nextStyle.insert(.strong)
            }
        }
        for grandchild in element.children {
            collectInline(grandchild, style: nextStyle, link: nextLink, isNote: nextIsNote, into: &segments, images: &images, ids: &ids)
        }
    }

    /// EPUB 3 marks note references (`epub:type="noteref"`); EPUB 2 books do not, so a link to
    /// a fragment is also a note when it looks like one: a superscript, a "note" class, or a
    /// short label such as `3`, `[12]` or `*`.
    static func isNoteReference(_ link: XMLNode, target: String, insideSuperscript: Bool) -> Bool {
        let types = epubTypes(link)
        if types.contains("noteref") { return true }
        if types.contains("backlink") { return false }
        guard target.contains("#") else { return false }
        if insideSuperscript || link.firstElement(named: "sup") != nil { return true }
        let classes = (link.attribute("class") ?? "").lowercased()
        if classes.contains("note") || classes.contains("footnote") { return true }
        let label = TextCanonicalizer.canonicalText(link.rawText)
        guard !label.isEmpty, label.count <= 6 else { return false }
        let core = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        return !core.isEmpty && core.allSatisfy { $0.isNumber || $0 == "*" }
    }

    static func noteLabel(_ link: XMLNode) -> String {
        TextCanonicalizer.canonicalText(link.rawText).trimmingCharacters(in: CharacterSet(charactersIn: "[]() "))
    }
}

/// Container paths: always `/`-separated, relative to the container root, percent-decoded.
enum EPUBPath {
    static func hasScheme(_ href: String) -> Bool {
        guard let colon = href.firstIndex(of: ":") else { return false }
        let scheme = href[..<colon]
        return !scheme.isEmpty && !scheme.contains("/") && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[...slash])
    }

    /// Resolves `href` against the document at `base`, handling `./`, `../` and root-relative paths.
    static func resolve(_ href: String, relativeTo base: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let joined = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : directory(of: base) + decoded
        var parts: [Substring] = []
        for part in joined.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }
}

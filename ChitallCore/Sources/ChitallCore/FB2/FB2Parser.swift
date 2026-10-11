import Foundation

public struct FB2ParseResult: Sendable {
    public let book: ReadableBook
    public let encoding: SourceEncoding
    /// The declared encoding did not match the bytes and windows-1251 was used instead.
    public let usedEncodingFallback: Bool
}

/// FB2 → `ReadableBook`. Paths in anchors are computed from the source XML and are what
/// locators store, so the traversal below defines which elements are blocks.
public enum FB2Parser {
    static let noteBodyNames: Set<String> = ["notes", "comments", "footnotes"]

    public static func parse(_ data: Data) throws -> FB2ParseResult {
        guard data.contains(where: { !$0.isXMLWhitespace }) else { throw BookImportError.emptyFile }
        let decoded = try XMLTextDecoder.decode(data)
        let root = try XMLTreeReader.read(decoded.utf8Data)
        guard root.name == "FictionBook" else { throw BookImportError.notFictionBook(rootElement: root.name) }

        let metadata = parseMetadata(root.firstElement(named: "description"))
        let bodies = root.elements(named: "body")
        guard !bodies.isEmpty else { throw BookImportError.noBody }

        let mainIndex = bodies.firstIndex { !noteBodyNames.contains(($0.attribute("name") ?? "").lowercased()) } ?? 0
        var builder = BlockBuilder()

        // Chapters must follow document order so that block ordinals do.
        for (index, body) in bodies.enumerated() {
            if index == mainIndex {
                let plans = chapterPlans(
                    children: body.elements,
                    looseTitle: titleText(of: body) ?? "Начало",
                    containerPath: body.path,
                    depth: 1
                )
                for plan in plans { builder.buildChapter(plan, context: [], isNotes: false) }
            } else {
                let title = titleText(of: body) ?? defaultNotesTitle(body.attribute("name"))
                let plan = ChapterPlan(title: title, path: body.path, nodes: body.elements, depth: 1, rootIsSection: false)
                builder.buildChapter(plan, context: .notes, isNotes: true)
            }
        }

        let mainHasText = builder.chapters.contains { !$0.isNotes && $0.blocks.contains(where: \.hasText) }
        guard mainHasText else { throw BookImportError.noText }

        var neededImages = builder.imageIDs
        if let cover = metadata.coverImageID { neededImages.insert(cover) }
        let images = decodeBinaries(root.elements(named: "binary"), ids: neededImages)

        let book = ReadableBook(
            format: .fb2,
            metadata: metadata,
            chapters: builder.chapters,
            notes: builder.notes,
            images: images,
            idTargets: builder.idTargets
        )
        return FB2ParseResult(book: book, encoding: decoded.encoding, usedEncodingFallback: decoded.usedFallback)
    }

    // MARK: - Chapter planning

    struct ChapterPlan {
        var title: String
        var path: String
        var nodes: [XMLNode]
        var depth: Int
        /// The chapter is exactly one `section`; its own title is not repeated in the TOC.
        var rootIsSection: Bool
    }

    /// Splits a container's children into reading units. Top-level sections become chapters.
    /// When a container holds a single section that itself holds several sections (a book
    /// wrapped into one "part"), its subsections become the chapters instead.
    static func chapterPlans(children: [XMLNode], looseTitle: String, containerPath: String, depth: Int) -> [ChapterPlan] {
        let sections = children.filter { $0.name == "section" }
        let unwrapSingle = sections.count == 1 && sections[0].elements(named: "section").count >= 2
        var plans: [ChapterPlan] = []
        var loose: [XMLNode] = []
        var sectionNumber = 0

        func flushLoose() {
            guard !loose.isEmpty else { return }
            plans.append(ChapterPlan(title: looseTitle, path: containerPath, nodes: loose, depth: depth, rootIsSection: false))
            loose = []
        }

        for child in children {
            guard child.name == "section" else {
                loose.append(child)
                continue
            }
            flushLoose()
            sectionNumber += 1
            let title = titleText(of: child) ?? "Раздел \(sectionNumber)"
            if unwrapSingle {
                plans += chapterPlans(children: child.elements, looseTitle: title, containerPath: child.path, depth: depth + 1)
            } else {
                plans.append(ChapterPlan(title: title, path: child.path, nodes: [child], depth: depth, rootIsSection: true))
            }
        }
        flushLoose()
        return plans
    }

    static func titleText(of node: XMLNode) -> String? {
        guard let title = node.firstElement(named: "title") else { return nil }
        let parts = title.elements(named: "p")
            .map { TextCanonicalizer.canonicalText($0.rawText) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return joinTitleParts(parts)
    }

    /// "Глава 1" + "Возвращение" → "Глава 1. Возвращение"; no extra dot after punctuation.
    static func joinTitleParts(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            if result.isEmpty {
                result = part
            } else if let last = result.last, ".!?:;…".contains(last) {
                result += " " + part
            } else {
                result += ". " + part
            }
        }
        return result
    }

    static func defaultNotesTitle(_ name: String?) -> String {
        switch (name ?? "").lowercased() {
        case "comments": return "Комментарии"
        default: return "Примечания"
        }
    }

    // MARK: - Metadata

    static func parseMetadata(_ description: XMLNode?) -> BookMetadata {
        var metadata = BookMetadata()
        guard let description else { return metadata }

        func text(_ node: XMLNode?) -> String? {
            guard let node else { return nil }
            let value = TextCanonicalizer.canonicalText(node.rawText)
            return value.isEmpty ? nil : value
        }

        if let info = description.firstElement(named: "title-info") {
            metadata.title = text(info.firstElement(named: "book-title")) ?? ""
            metadata.genres = info.elements(named: "genre").compactMap { text($0) }
            metadata.authors = info.elements(named: "author").compactMap(person)
            metadata.translators = info.elements(named: "translator").compactMap(person)
            metadata.language = text(info.firstElement(named: "lang"))
            metadata.sourceLanguage = text(info.firstElement(named: "src-lang"))
            if let keywords = text(info.firstElement(named: "keywords")) {
                metadata.keywords = keywords.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
            if let date = info.firstElement(named: "date") {
                metadata.date = text(date) ?? date.attribute("value")
            }
            if let annotation = info.firstElement(named: "annotation") {
                let paragraphs = annotation.elements
                    .map { TextCanonicalizer.canonicalText($0.rawText) }
                    .filter { !$0.isEmpty }
                let joined = paragraphs.isEmpty ? text(annotation) : paragraphs.joined(separator: "\n")
                metadata.annotation = joined
            }
            if let sequence = info.firstElement(named: "sequence"),
               let name = sequence.attribute("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                metadata.series = BookSeries(name: name, number: sequence.attribute("number"))
            }
            if let cover = info.firstElement(named: "coverpage")?.firstElement(named: "image"),
               let href = cover.attribute("href") {
                metadata.coverImageID = internalID(href)
            }
        }
        if let document = description.firstElement(named: "document-info") {
            metadata.documentID = text(document.firstElement(named: "id"))
            metadata.documentVersion = text(document.firstElement(named: "version"))
        }
        if let publish = description.firstElement(named: "publish-info") {
            metadata.publisher = text(publish.firstElement(named: "publisher"))
            metadata.publishYear = text(publish.firstElement(named: "year"))
            metadata.isbn = text(publish.firstElement(named: "isbn"))
            if metadata.title.isEmpty {
                metadata.title = text(publish.firstElement(named: "book-name")) ?? ""
            }
        }
        return metadata
    }

    static func person(_ node: XMLNode) -> Person? {
        func part(_ name: String) -> String {
            TextCanonicalizer.canonicalText(node.firstElement(named: name)?.rawText ?? "")
        }
        let person = Person(
            firstName: part("first-name"),
            middleName: part("middle-name"),
            lastName: part("last-name"),
            nickname: part("nickname")
        )
        return person.displayName.isEmpty ? nil : person
    }

    static func internalID(_ href: String) -> String {
        href.hasPrefix("#") ? String(href.dropFirst()) : href
    }

    static func decodeBinaries(_ nodes: [XMLNode], ids: Set<String>) -> [String: BookImage] {
        var images: [String: BookImage] = [:]
        for node in nodes {
            guard let id = node.attribute("id"), ids.contains(id), images[id] == nil else { continue }
            guard let data = Data(base64Encoded: node.rawText, options: .ignoreUnknownCharacters), !data.isEmpty else {
                continue
            }
            let contentType = node.attribute("content-type") ?? "application/octet-stream"
            images[id] = BookImage(id: id, contentType: contentType, data: data)
        }
        return images
    }
}

// MARK: - Block building

/// Walks planned chapters and produces blocks with global ordinals in document order.
struct BlockBuilder {
    private(set) var chapters: [Chapter] = []
    private(set) var notes: [String: NoteContent] = [:]
    private(set) var idTargets: [String: Int] = [:]
    private(set) var imageIDs: Set<String> = []

    private var nextOrdinal = 0
    private var blocks: [Block] = []
    private var toc: [TOCEntry] = []
    private var chapterIndex = 0
    private var chapterDepth = 1
    private var chapterRootPath = ""

    struct Walk {
        var context: BlockContext
        /// Depth of the innermost enclosing section: 0 at body level, 1 for top-level sections.
        var sectionDepth: Int
    }

    mutating func buildChapter(_ plan: FB2Parser.ChapterPlan, context: BlockContext, isNotes: Bool) {
        blocks = []
        toc = []
        chapterIndex = chapters.count
        chapterDepth = plan.depth
        chapterRootPath = plan.rootIsSection ? (plan.nodes.first?.path ?? "") : ""
        let walk = Walk(context: context, sectionDepth: plan.depth - 1)
        for node in plan.nodes { visit(node, walk) }
        guard !blocks.isEmpty else { return }
        chapters.append(Chapter(
            index: chapterIndex,
            title: plan.title,
            anchor: TextAnchor(path: plan.path),
            blocks: blocks,
            tableOfContents: toc,
            isNotes: isNotes
        ))
    }

    private mutating func visit(_ node: XMLNode, _ walk: Walk) {
        switch node.name {
        case "section":
            visitSection(node, walk)
        case "title":
            visitTitle(node, walk)
        case "epigraph":
            visitChildren(node, Walk(context: walk.context.union(.epigraph), sectionDepth: walk.sectionDepth))
        case "cite":
            visitChildren(node, Walk(context: walk.context.union(.cite), sectionDepth: walk.sectionDepth))
        case "annotation":
            visitChildren(node, Walk(context: walk.context.union(.annotation), sectionDepth: walk.sectionDepth))
        case "poem", "stanza":
            visitPoemPart(node, Walk(context: walk.context.union(.poem), sectionDepth: walk.sectionDepth))
        case "table", "tr":
            visitChildren(node, Walk(context: walk.context.union(.table), sectionDepth: walk.sectionDepth))
        case "p":
            appendParagraph(node, role: .paragraph, walk)
        case "v":
            appendParagraph(node, role: .verse, walk)
        case "subtitle":
            appendParagraph(node, role: .subtitle, walk)
        case "text-author":
            appendParagraph(node, role: .textAuthor, walk)
        case "date":
            appendParagraph(node, role: .date, walk)
        case "td", "th":
            appendParagraph(node, role: .tableCell, walk)
        case "empty-line":
            appendBlock(Block(ordinal: nextOrdinal, anchor: TextAnchor(path: node.path), role: .emptyLine, context: walk.context, text: ""))
        case "image":
            let id = node.attribute("href").map(FB2Parser.internalID)
            if let id { imageIDs.insert(id) }
            appendBlock(Block(
                ordinal: nextOrdinal,
                anchor: TextAnchor(path: node.path),
                role: .image,
                context: walk.context,
                text: "",
                elementID: node.attribute("id"),
                imageID: id
            ))
        default:
            // Unknown elements are treated as transparent containers.
            visitChildren(node, walk)
        }
    }

    private mutating func visitSection(_ node: XMLNode, _ walk: Walk) {
        let depth = walk.sectionDepth + 1
        if let id = node.attribute("id"), idTargets[id] == nil { idTargets[id] = nextOrdinal }
        if node.path != chapterRootPath, let title = FB2Parser.titleText(of: node) {
            toc.append(TOCEntry(title: title, depth: max(1, depth - chapterDepth), firstBlock: nextOrdinal))
        }
        let firstIndex = blocks.count
        visitChildren(node, Walk(context: walk.context, sectionDepth: depth))

        if walk.context.contains(.notes), let id = node.attribute("id"), notes[id] == nil {
            let sectionBlocks = blocks[firstIndex...]
            let title = sectionBlocks.filter { $0.role == .title && $0.hasText }.map(\.text)
            let body = sectionBlocks.filter { $0.role != .title && $0.hasText }.map(\.text)
            notes[id] = NoteContent(
                id: id,
                title: FB2Parser.joinTitleParts(title),
                text: body.joined(separator: "\n"),
                chapterIndex: chapterIndex,
                firstBlock: sectionBlocks.first?.ordinal ?? nextOrdinal
            )
        }
    }

    private mutating func visitTitle(_ node: XMLNode, _ walk: Walk) {
        for child in node.children {
            switch child {
            case let .element(element) where element.name == "p":
                appendParagraph(element, role: .title, walk, titleLevel: walk.sectionDepth)
            case let .element(element):
                visit(element, walk)
            case let .text(text, path):
                appendStrayText(text, path: path, role: .title, walk)
            }
        }
    }

    private mutating func visitPoemPart(_ node: XMLNode, _ walk: Walk) {
        for child in node.children {
            switch child {
            case let .element(element) where element.name == "title":
                // Poem and stanza titles are typographically subtitles, not headings.
                for paragraph in element.elements(named: "p") {
                    appendParagraph(paragraph, role: .subtitle, walk)
                }
            case let .element(element):
                visit(element, walk)
            case let .text(text, path):
                appendStrayText(text, path: path, role: .verse, walk)
            }
        }
    }

    private mutating func visitChildren(_ node: XMLNode, _ walk: Walk) {
        for child in node.children {
            switch child {
            case let .element(element):
                visit(element, walk)
            case let .text(text, path):
                appendStrayText(text, path: path, role: .paragraph, walk)
            }
        }
    }

    /// Non-whitespace text directly inside a container (outside any `p`): invalid FB2 that
    /// exists in the wild. It becomes a paragraph anchored at the text node, e.g. `…/text()[2]`.
    private mutating func appendStrayText(_ text: String, path: String, role: BlockRole, _ walk: Walk) {
        let canonical = TextCanonicalizer.canonicalize([.init(text: text)])
        guard !canonical.text.isEmpty else { return }
        appendBlock(Block(
            ordinal: nextOrdinal,
            anchor: TextAnchor(path: path),
            role: role,
            context: walk.context,
            titleLevel: role == .title ? walk.sectionDepth : 0,
            text: canonical.text
        ))
    }

    private mutating func appendParagraph(_ node: XMLNode, role: BlockRole, _ walk: Walk, titleLevel: Int = 0) {
        var segments: [TextCanonicalizer.Segment] = []
        Self.collectInline(node, style: [], link: nil, isNote: false, into: &segments)
        let canonical = TextCanonicalizer.canonicalize(segments)
        let id = node.attribute("id")
        if let id, idTargets[id] == nil { idTargets[id] = nextOrdinal }
        appendBlock(Block(
            ordinal: nextOrdinal,
            anchor: TextAnchor(path: node.path),
            role: role,
            context: walk.context,
            titleLevel: titleLevel,
            text: canonical.text,
            runs: canonical.runs,
            elementID: id
        ))
    }

    private mutating func appendBlock(_ block: Block) {
        blocks.append(block)
        nextOrdinal += 1
    }

    static func collectInline(
        _ node: XMLNode,
        style: InlineStyle,
        link: String?,
        isNote: Bool,
        into segments: inout [TextCanonicalizer.Segment]
    ) {
        for child in node.children {
            switch child {
            case let .text(text, _):
                segments.append(.init(text: text, style: style, link: link, isNoteReference: isNote))
            case let .element(element):
                var nextStyle = style
                var nextLink = link
                var nextIsNote = isNote
                switch element.name {
                case "strong": nextStyle.insert(.strong)
                case "emphasis": nextStyle.insert(.emphasis)
                case "strikethrough": nextStyle.insert(.strikethrough)
                case "sub": nextStyle.insert(.subscript_)
                case "sup": nextStyle.insert(.superscript)
                case "code": nextStyle.insert(.code)
                case "a":
                    nextLink = element.attribute("href").map(FB2Parser.internalID)
                    nextIsNote = element.attribute("type")?.lowercased() == "note"
                case "image":
                    // Inline images are not rendered in the MVP and carry no text.
                    continue
                default:
                    break
                }
                collectInline(element, style: nextStyle, link: nextLink, isNote: nextIsNote, into: &segments)
            }
        }
    }
}

extension UInt8 {
    var isXMLWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}

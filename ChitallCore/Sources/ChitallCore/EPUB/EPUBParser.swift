import Foundation

/// EPUB 2 / EPUB 3 (reflowable, DRM-free) → `ReadableBook`.
///
/// The container is read with `ZipArchive`; `META-INF/container.xml` names the package (OPF):
/// metadata, manifest, spine and the cover. Each spine document becomes one chapter; the
/// navigation document (EPUB 3) or the NCX (EPUB 2) names the chapters and the headings inside
/// them. Block anchors are `resource` = container path of the document + `path` inside its
/// XHTML, the same locator v1 as FB2 (docs/locator.md).
public enum EPUBParser {
    static let containerPath = "META-INF/container.xml"
    static let encryptionPath = "META-INF/encryption.xml"
    /// Font obfuscation (IDPF, Adobe) is not DRM: the text is readable.
    static let fontObfuscation: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// A ZIP that declares itself an EPUB: the `mimetype` entry or a container document.
    public static func isEPUB(_ archive: ZipArchive) -> Bool {
        archive.entries.contains { $0.name == "mimetype" || $0.name == containerPath }
            && !archive.entries.contains { $0.name.lowercased().hasSuffix(".fb2") }
    }

    public static func parse(_ data: Data, inflater: ZipArchive.Inflater? = ZipArchive.systemInflater) throws -> ReadableBook {
        try parse(BookImporter.openArchive(data), inflater: inflater)
    }

    static func parse(_ archive: ZipArchive, inflater: ZipArchive.Inflater?) throws -> ReadableBook {
        let files = ContainerFiles(archive: archive, inflater: inflater)
        try checkForDRM(files)

        guard let containerXML = try files.data(containerPath) else {
            throw BookImportError.damagedEPUB("нет файла META-INF/container.xml")
        }
        let container = try files.xml(containerXML, resource: containerPath)
        let rootfiles = container.descendants(named: "rootfile")
        let packagePath = (rootfiles.first { $0.attribute("media-type") == "application/oebps-package+xml" } ?? rootfiles.first)?
            .attribute("full-path")
            .map { EPUBPath.resolve($0, relativeTo: "") }
            ?? archive.entries.first { $0.name.lowercased().hasSuffix(".opf") }?.name
        guard let packagePath, let packageData = try files.data(packagePath) else {
            throw BookImportError.damagedEPUB("не найдено описание книги (OPF)")
        }
        let package = try Package(files.xml(packageData, resource: packagePath), path: packagePath)
        guard !package.spine.isEmpty else { throw BookImportError.damagedEPUB("в книге нет списка глав (spine)") }

        // Content documents.
        var documents: [XHTMLDocument] = []
        var linearFlags: [Bool] = []
        for item in package.spine {
            guard let manifest = package.manifest[item.idref], manifest.isContentDocument,
                  let data = try files.data(manifest.path) else { continue }
            let root = try files.xml(data, resource: manifest.path)
            guard let body = root.firstElement(named: "body") ?? root.descendants(named: "body").first else { continue }
            documents.append(XHTMLDocument(resource: manifest.path, root: root, body: body))
            linearFlags.append(item.linear)
        }

        // Blocks.
        var builder = XHTMLBlockBuilder()
        var pending: [(document: XHTMLDocument, blocks: [Block], linear: Bool)] = []
        var resourceStarts: [String: Int] = [:]
        for (document, linear) in zip(documents, linearFlags) {
            let first = builder.nextOrdinal
            let blocks = builder.build(document)
            guard !blocks.isEmpty else { continue }
            resourceStarts[document.resource] = first
            pending.append((document, blocks, linear))
        }
        var idTargets = builder.idTargets
        for (resource, ordinal) in resourceStarts { idTargets[resource] = ordinal }

        // Notes: the text behind every note reference, shown in a card on tap.
        let nodes = IDIndex(documents)
        var notes: [String: NoteContent] = [:]
        var backlinks: Set<String> = []
        for key in builder.noteReferenceOrder {
            guard let target = nodes.node(for: key) else { continue }
            if target.isBacklinkTarget {
                backlinks.insert(key)
                continue
            }
            var fragmentBuilder = XHTMLBlockBuilder()
            let texts = fragmentBuilder.buildFragment(target.block, resource: target.resource).filter(\.hasText).map(\.text)
            let text = texts.joined(separator: "\n")
            guard !text.isEmpty, text.unicodeScalars.count <= 6000 else { continue }
            notes[key] = NoteContent(
                id: key,
                title: builder.noteReferences[key] ?? "",
                text: text,
                chapterIndex: 0,
                firstBlock: idTargets[key] ?? 0
            )
        }

        // Chapters, named by the table of contents.
        let navigation = package.navigation(files: files)
        var chapters: [Chapter] = []
        for (number, item) in pending.enumerated() {
            let blocks = backlinks.isEmpty ? item.blocks : item.blocks.map { removeNoteStyle(from: $0, links: backlinks) }
            let resource = item.document.resource
            let firstBlock = blocks[0].ordinal
            let lastBlock = blocks[blocks.count - 1].ordinal
            let entries = navigation.filter { $0.resource == resource }
            let heads = entries.filter { entry in
                guard let fragment = entry.fragment else { return true }
                return (idTargets[resource + "#" + fragment] ?? firstBlock) <= firstBlock
            }
            let head = heads.last
            var toc: [TOCEntry] = []
            let baseDepth = head?.depth ?? ((entries.map(\.depth).min() ?? 1) - 1)
            for entry in entries where !heads.contains(entry) {
                guard let fragment = entry.fragment, let ordinal = idTargets[resource + "#" + fragment],
                      ordinal > firstBlock, ordinal <= lastBlock else { continue }
                toc.append(TOCEntry(title: entry.title, depth: max(1, entry.depth - baseDepth), firstBlock: ordinal))
            }
            let title = head?.title
                ?? blocks.first { $0.role == .title && $0.hasText }.map { $0.text.replacingOccurrences(of: "\u{2028}", with: " ") }
                ?? fallbackTitle(blocks, cover: package.coverPath, number: number + 1)
            chapters.append(Chapter(
                index: chapters.count,
                title: title,
                anchor: TextAnchor(resource: resource, path: item.document.body.path),
                blocks: blocks,
                tableOfContents: toc,
                isNotes: isNotesDocument(item.document)
            ))
        }
        guard chapters.contains(where: { !$0.isNotes && $0.blocks.contains(where: \.hasText) }) else {
            throw BookImportError.noText
        }

        // Chapter indices of the notes, now that chapters are known.
        var chapterOfBlock: [Int: Int] = [:]
        for chapter in chapters { for block in chapter.blocks { chapterOfBlock[block.ordinal] = chapter.index } }
        for (key, note) in notes {
            let nearest = chapterOfBlock[note.firstBlock] ?? chapterOfBlock[note.firstBlock - 1] ?? 0
            notes[key] = NoteContent(id: note.id, title: note.title, text: note.text, chapterIndex: nearest, firstBlock: note.firstBlock)
        }

        // Images: the ones shown as blocks, and the cover.
        var images: [String: BookImage] = [:]
        var wanted = builder.imagePaths
        if let cover = package.coverPath { wanted.insert(cover) }
        for path in wanted {
            guard let data = try? files.data(path), !data.isEmpty else { continue }
            images[path] = BookImage(id: path, contentType: package.mediaType(of: path), data: data)
        }
        var metadata = package.metadata
        metadata.coverImageID = package.coverPath.flatMap { images[$0] == nil ? nil : $0 }

        return ReadableBook(
            format: .epub,
            metadata: metadata,
            chapters: chapters,
            notes: notes,
            images: images,
            idTargets: idTargets
        )
    }

    private static func fallbackTitle(_ blocks: [Block], cover: String?, number: Int) -> String {
        if !blocks.contains(where: \.hasText) {
            return blocks.contains { $0.imageID != nil && $0.imageID == cover } ? "Обложка" : "Иллюстрация"
        }
        return "Раздел \(number)"
    }

    private static func isNotesDocument(_ document: XHTMLDocument) -> Bool {
        let noteKinds: Set<String> = ["footnotes", "endnotes", "rearnotes"]
        let types = XHTMLBlockBuilder.epubTypes(document.body)
            + document.body.elements.prefix(1).flatMap(XHTMLBlockBuilder.epubTypes)
        return types.contains { noteKinds.contains($0) }
    }

    /// A link back from a note to its reference is an ordinary link, not another note.
    private static func removeNoteStyle(from block: Block, links: Set<String>) -> Block {
        guard block.runs.contains(where: { $0.isNoteReference && $0.link.map(links.contains) == true }) else { return block }
        let runs = block.runs.map { run -> InlineRun in
            guard run.isNoteReference, let link = run.link, links.contains(link) else { return run }
            return InlineRun(range: run.range, style: run.style, link: run.link, isNoteReference: false)
        }
        return Block(
            ordinal: block.ordinal, anchor: block.anchor, role: block.role, context: block.context,
            titleLevel: block.titleLevel, text: block.text, runs: runs, elementID: block.elementID, imageID: block.imageID
        )
    }

    // MARK: DRM

    /// Encrypted content (Adobe ADEPT, Apple FairPlay, Readium LCP, …) cannot be read and is not
    /// worked around: the user gets a clear message instead.
    static func checkForDRM(_ files: ContainerFiles) throws {
        if files.archive.entries.contains(where: { $0.name == "META-INF/license.lcpl" }) {
            throw BookImportError.drmProtected
        }
        guard let data = try? files.data(encryptionPath) else { return }
        guard let root = try? XMLTreeReader.read(XMLTextDecoder.decode(data).utf8Data) else {
            if String(decoding: data, as: UTF8.self).contains("CipherReference") { throw BookImportError.drmProtected }
            return
        }
        for encrypted in root.descendants(named: "EncryptedData") {
            let algorithm = encrypted.descendants(named: "EncryptionMethod").first?.attribute("Algorithm") ?? ""
            if !fontObfuscation.contains(algorithm) { throw BookImportError.drmProtected }
        }
    }
}

// MARK: - Container

/// Entries of the ZIP by path, with a case-insensitive fallback for sloppy hrefs.
struct ContainerFiles {
    let archive: ZipArchive
    let inflater: ZipArchive.Inflater?
    private let byName: [String: ZipArchive.Entry]
    private let byLowercasedName: [String: ZipArchive.Entry]

    init(archive: ZipArchive, inflater: ZipArchive.Inflater?) {
        self.archive = archive
        self.inflater = inflater
        var byName: [String: ZipArchive.Entry] = [:]
        var byLowercasedName: [String: ZipArchive.Entry] = [:]
        for entry in archive.entries where !entry.isDirectory {
            byName[entry.name] = entry
            byLowercasedName[entry.name.lowercased()] = byLowercasedName[entry.name.lowercased()] ?? entry
        }
        self.byName = byName
        self.byLowercasedName = byLowercasedName
    }

    func data(_ path: String) throws -> Data? {
        guard let entry = byName[path] ?? byLowercasedName[path.lowercased()] else { return nil }
        do {
            return try archive.data(for: entry, inflater: inflater)
        } catch let failure as ZipArchive.Failure {
            switch failure {
            case let .unsupported(reason): throw BookImportError.unsupportedArchive(reason)
            case .tooLarge: throw BookImportError.fileTooLarge(bytes: entry.uncompressedSize, limit: ZipArchive.maximumEntrySize)
            case .notAnArchive, .damaged, .checksumMismatch: throw BookImportError.damagedEPUB("испорчен файл «\(path)»")
            }
        }
    }

    /// XML of a container file. EPUB 2 XHTML uses HTML entities (`&nbsp;`) declared only in a
    /// DTD that is never loaded, so they are turned into character references first.
    func xml(_ data: Data, resource: String) throws -> XMLNode {
        do {
            let decoded = try XMLTextDecoder.decode(data)
            return try XMLTreeReader.read(HTMLEntityRewriter.rewrite(decoded.utf8Data))
        } catch BookImportError.malformedXML(let line, let column, _) {
            throw BookImportError.damagedEPUB("ошибка XML в «\(resource)», строка \(line), позиция \(column)")
        }
    }
}

// MARK: - Package document

struct Package {
    struct ManifestItem {
        let id: String
        let path: String
        let mediaType: String
        let properties: [String]

        var isContentDocument: Bool {
            mediaType == "application/xhtml+xml" || mediaType == "text/html" || mediaType == "application/x-dtbook+xml"
                || (mediaType.isEmpty && (path.hasSuffix(".xhtml") || path.hasSuffix(".html") || path.hasSuffix(".htm")))
        }
    }

    struct SpineItem {
        let idref: String
        let linear: Bool
    }

    let path: String
    let metadata: BookMetadata
    let manifest: [String: ManifestItem]
    let spine: [SpineItem]
    let coverPath: String?
    private let mediaTypes: [String: String]
    private let navPath: String?
    private let ncxPath: String?

    init(_ root: XMLNode, path: String) throws {
        guard root.name == "package" else { throw BookImportError.damagedEPUB("описание книги (OPF) не в формате EPUB") }
        self.path = path
        var manifest: [String: ManifestItem] = [:]
        var mediaTypes: [String: String] = [:]
        for item in root.firstElement(named: "manifest")?.elements(named: "item") ?? [] {
            guard let id = item.attribute("id"), let href = item.attribute("href") else { continue }
            let resolved = EPUBPath.resolve(href, relativeTo: path)
            let entry = ManifestItem(
                id: id,
                path: resolved,
                mediaType: (item.attribute("media-type") ?? "").lowercased(),
                properties: (item.attribute("properties") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            )
            manifest[id] = entry
            mediaTypes[resolved] = entry.mediaType
        }
        self.manifest = manifest
        self.mediaTypes = mediaTypes

        let spineNode = root.firstElement(named: "spine")
        self.spine = (spineNode?.elements(named: "itemref") ?? []).compactMap { itemref in
            itemref.attribute("idref").map { SpineItem(idref: $0, linear: itemref.attribute("linear") != "no") }
        }
        self.navPath = manifest.values.first { $0.properties.contains("nav") }?.path
        self.ncxPath = spineNode?.attribute("toc").flatMap { manifest[$0]?.path }
            ?? manifest.values.first { $0.mediaType == "application/x-dtbncx+xml" }?.path

        let metadataNode = root.firstElement(named: "metadata")
            ?? root.descendants(named: "metadata").first
        self.metadata = Self.parseMetadata(metadataNode, uniqueIdentifier: root.attribute("unique-identifier"))
        self.coverPath = Self.cover(manifest: manifest, metadata: metadataNode, guide: root.firstElement(named: "guide"), packagePath: path)
    }

    func mediaType(of path: String) -> String {
        if let type = mediaTypes[path], !type.isEmpty { return type }
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    // MARK: Cover

    private static func cover(manifest: [String: ManifestItem], metadata: XMLNode?, guide: XMLNode?, packagePath: String) -> String? {
        let images = manifest.values.filter { $0.mediaType.hasPrefix("image/") }
        // EPUB 3.
        if let item = images.first(where: { $0.properties.contains("cover-image") }) { return item.path }
        // EPUB 2: <meta name="cover" content="item-id"/>.
        if let content = metadata?.elements(named: "meta").first(where: { $0.attribute("name") == "cover" })?.attribute("content") {
            if let item = manifest[content], item.mediaType.hasPrefix("image/") { return item.path }
            if let item = images.first(where: { $0.path == EPUBPath.resolve(content, relativeTo: packagePath) }) { return item.path }
        }
        // By name, the way many EPUB 2 tools write it.
        let named = images.filter { $0.id.lowercased().contains("cover") || ($0.path as NSString).lastPathComponent.lowercased().contains("cover") }
        return named.min { $0.path < $1.path }?.path
    }

    // MARK: Metadata

    private static func parseMetadata(_ node: XMLNode?, uniqueIdentifier: String?) -> BookMetadata {
        var metadata = BookMetadata()
        guard let node else { return metadata }
        func text(_ element: XMLNode) -> String? {
            let value = TextCanonicalizer.canonicalText(element.rawText)
            return value.isEmpty ? nil : value
        }
        let metas = node.elements(named: "meta")
        /// EPUB 3 `<meta refines="#id" property="…">`.
        func refinement(_ id: String?, _ property: String) -> String? {
            guard let id else { return nil }
            return metas.first { $0.attribute("refines") == "#" + id && $0.attribute("property") == property }.flatMap(text)
        }

        let titles = node.elements(named: "title")
        let mainTitle = titles.first { refinement($0.attribute("id"), "title-type") == "main" } ?? titles.first
        metadata.title = mainTitle.flatMap(text) ?? ""

        for creator in node.elements(named: "creator") + node.elements(named: "contributor") {
            guard let name = text(creator) else { continue }
            let role = (creator.attribute("role") ?? refinement(creator.attribute("id"), "role") ?? (creator.name == "creator" ? "aut" : ""))
                .lowercased()
            switch role {
            case "aut": metadata.authors.append(Person(firstName: name))
            case "trl": metadata.translators.append(Person(firstName: name))
            default: break
            }
        }
        metadata.language = node.elements(named: "language").first.flatMap(text)
        metadata.publisher = node.elements(named: "publisher").first.flatMap(text)
        metadata.date = node.elements(named: "date").first.flatMap(text)
        if let year = metadata.date?.prefix(4), year.count == 4, year.allSatisfy(\.isNumber) { metadata.publishYear = String(year) }
        metadata.genres = node.elements(named: "subject").compactMap(text)
        if let description = node.elements(named: "description").first.flatMap(text) {
            metadata.annotation = HTMLText.plain(description)
        }
        let identifiers = node.elements(named: "identifier")
        metadata.documentID = (identifiers.first { $0.attribute("id") == uniqueIdentifier } ?? identifiers.first).flatMap(text)
        for identifier in identifiers {
            guard let value = text(identifier) else { continue }
            let isISBN = (identifier.attribute("scheme") ?? "").lowercased() == "isbn" || value.lowercased().hasPrefix("urn:isbn:")
            if isISBN, metadata.isbn == nil {
                metadata.isbn = value.lowercased().hasPrefix("urn:isbn:") ? String(value.dropFirst(9)) : value
            }
        }
        // Series: EPUB 3 collections or Calibre's meta.
        if let collection = metas.first(where: { $0.attribute("property") == "belongs-to-collection" }), let name = text(collection) {
            metadata.series = BookSeries(name: name, number: refinement(collection.attribute("id"), "group-position"))
        } else if let name = metas.first(where: { $0.attribute("name") == "calibre:series" })?.attribute("content"), !name.isEmpty {
            let number = metas.first { $0.attribute("name") == "calibre:series_index" }?.attribute("content")
            metadata.series = BookSeries(name: name, number: number.map(Self.trimmedNumber))
        }
        return metadata
    }

    /// Calibre writes "2.0" for the second book.
    private static func trimmedNumber(_ value: String) -> String {
        value.hasSuffix(".0") ? String(value.dropLast(2)) : value
    }

    // MARK: Navigation

    struct NavigationEntry: Equatable {
        let title: String
        let depth: Int
        let resource: String
        let fragment: String?
    }

    /// The table of contents in reading order: EPUB 3 navigation document, else the EPUB 2 NCX.
    /// A broken one only costs chapter names, never the book.
    func navigation(files: ContainerFiles) -> [NavigationEntry] {
        if let navPath, let data = try? files.data(navPath), let root = try? files.xml(data, resource: navPath) {
            let navs = root.descendants(named: "nav")
            if let toc = navs.first(where: { XHTMLBlockBuilder.epubTypes($0).contains("toc") }) ?? navs.first,
               let list = toc.descendants(named: "ol").first {
                let entries = Self.navEntries(list, depth: 1, base: navPath)
                if !entries.isEmpty { return entries }
            }
        }
        if let ncxPath, let data = try? files.data(ncxPath), let root = try? files.xml(data, resource: ncxPath),
           let map = root.descendants(named: "navMap").first {
            return Self.ncxEntries(map, depth: 1, base: ncxPath)
        }
        return []
    }

    private static func entry(title: String, href: String?, depth: Int, base: String) -> NavigationEntry? {
        guard !title.isEmpty, let href, let target = EPUBLinkResolver(resource: base).target(href) else { return nil }
        let parts = target.split(separator: "#", maxSplits: 1).map(String.init)
        return NavigationEntry(title: title, depth: depth, resource: parts[0], fragment: parts.count > 1 ? parts[1] : nil)
    }

    private static func navEntries(_ list: XMLNode, depth: Int, base: String) -> [NavigationEntry] {
        var result: [NavigationEntry] = []
        for item in list.elements(named: "li") {
            let label = item.firstElement(named: "a") ?? item.firstElement(named: "span")
            let title = label.map { TextCanonicalizer.canonicalText($0.rawText) } ?? ""
            if let entry = entry(title: title, href: label?.attribute("href"), depth: depth, base: base) { result.append(entry) }
            if let nested = item.firstElement(named: "ol") {
                result += navEntries(nested, depth: depth + 1, base: base)
            }
        }
        return result
    }

    private static func ncxEntries(_ node: XMLNode, depth: Int, base: String) -> [NavigationEntry] {
        var result: [NavigationEntry] = []
        for point in node.elements(named: "navPoint") {
            let title = point.firstElement(named: "navLabel")?.firstElement(named: "text")
                .map { TextCanonicalizer.canonicalText($0.rawText) } ?? ""
            if let entry = entry(title: title, href: point.firstElement(named: "content")?.attribute("src"), depth: depth, base: base) {
                result.append(entry)
            }
            result += ncxEntries(point, depth: depth + 1, base: base)
        }
        return result
    }
}

// MARK: - Note targets

/// Elements with an `id` across all content documents, for reading the text behind a note link.
struct IDIndex {
    struct Target {
        let resource: String
        /// The nearest block-level element around the target (an `<a id>` inside a `<p>` → the `<p>`).
        let block: XMLNode
        /// The target is itself a note reference: the link pointing to it goes back to the text.
        let isBacklinkTarget: Bool
    }

    private var targets: [String: Target] = [:]

    init(_ documents: [XHTMLDocument]) {
        for document in documents { index(document.body, resource: document.resource, block: document.body) }
    }

    func node(for key: String) -> Target? { targets[key] }

    private mutating func index(_ node: XMLNode, resource: String, block: XMLNode) {
        let kind = XHTMLBlockBuilder.kind(of: node)
        let isBlock = kind == .block || node.name == "aside"
        let enclosing = isBlock ? node : block
        if let id = node.attribute("id"), !id.isEmpty, targets[resource + "#" + id] == nil {
            let isBacklink = Self.isReference(node) && !Self.starts(enclosing, with: node)
            targets[resource + "#" + id] = Target(resource: resource, block: enclosing, isBacklinkTarget: isBacklink)
        }
        for child in node.elements { index(child, resource: resource, block: enclosing) }
    }

    /// A note paragraph starts with its number (`<p><a id="n1" href="…#r1">1</a> Текст</p>`); a
    /// reference sits inside the text. Both are links with ids, so the position tells them apart.
    private static func starts(_ block: XMLNode, with node: XMLNode) -> Bool {
        TextCanonicalizer.canonicalText(block.rawText).hasPrefix(TextCanonicalizer.canonicalText(node.rawText))
    }

    /// `<a id="r1" href="notes.xhtml#n1">1</a>` or `<sup id="r1"><a href="…">1</a></sup>`.
    private static func isReference(_ node: XMLNode) -> Bool {
        guard XHTMLBlockBuilder.kind(of: node) == .inline else { return false }
        let hasLink = node.name == "a" ? node.attribute("href") != nil : !node.descendants(named: "a").filter { $0.attribute("href") != nil }.isEmpty
        return hasLink && TextCanonicalizer.canonicalText(node.rawText).count <= 8
    }
}

// MARK: - Helpers

extension XMLNode {
    /// All descendant elements with this local name, in document order.
    func descendants(named name: String) -> [XMLNode] {
        var result: [XMLNode] = []
        for child in elements {
            if child.name == name { result.append(child) }
            result += child.descendants(named: name)
        }
        return result
    }
}

/// Plain text of an HTML fragment stored as text, e.g. an OPF description with `<p>` tags.
enum HTMLText {
    static func plain(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        var text = ""
        var inTag = false
        var tag = ""
        for character in html {
            if inTag {
                if character == ">" {
                    inTag = false
                    let name = tag.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    if name.hasPrefix("p") || name.hasPrefix("br") || name.hasPrefix("div") || name.hasPrefix("li") { text += "\n" }
                } else {
                    tag.append(character)
                }
            } else if character == "<" {
                inTag = true
                tag = ""
            } else {
                text.append(character)
            }
        }
        let decoded = HTMLEntityRewriter.decodeText(text)
        return decoded.split(separator: "\n")
            .map { TextCanonicalizer.canonicalText(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Named HTML entities → numeric character references, before the XML parser sees the text.
enum HTMLEntityRewriter {
    static func rewrite(_ utf8: Data) -> Data {
        let bytes = [UInt8](utf8)
        guard bytes.contains(UInt8(ascii: "&")) else { return utf8 }
        // A document that declares its own entities keeps them; only known HTML names change.
        let declaresEntities = String(decoding: bytes.prefix(4096), as: UTF8.self).contains("<!ENTITY")
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 64)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "&") else {
                output.append(byte)
                index += 1
                continue
            }
            var end = index + 1
            while end < bytes.count, end - index <= 32, isNameByte(bytes[end]) { end += 1 }
            guard end > index + 1, end < bytes.count, bytes[end] == UInt8(ascii: ";"), isLetter(bytes[index + 1]) else {
                output.append(byte)
                index += 1
                continue
            }
            let name = String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
            if ["amp", "lt", "gt", "quot", "apos"].contains(name) {
                output.append(contentsOf: bytes[index...end])
            } else if let codePoint = HTMLEntities.codePoints[name] {
                output.append(contentsOf: Array("&#x\(String(codePoint, radix: 16));".utf8))
            } else if declaresEntities {
                output.append(contentsOf: bytes[index...end])
            } else {
                // Unknown name: keep it as visible text rather than fail on the whole book.
                output.append(contentsOf: Array("&amp;".utf8))
                output.append(contentsOf: bytes[(index + 1)...end])
            }
            index = end + 1
        }
        return Data(output)
    }

    /// Entities in already-parsed text (OPF descriptions with escaped HTML).
    static func decodeText(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let after = rest[rest.index(after: ampersand)...]
            if let semicolon = after.prefix(12).firstIndex(of: ";") {
                let name = String(after[..<semicolon])
                if let scalar = scalar(forEntity: name) {
                    result.unicodeScalars.append(scalar)
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }

    private static func scalar(forEntity name: String) -> Unicode.Scalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        if name.hasPrefix("#x") || name.hasPrefix("#X") { return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
        if name.hasPrefix("#") { return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init) }
        return HTMLEntities.codePoints[name].flatMap(Unicode.Scalar.init)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || (byte >= 0x30 && byte <= 0x39)
    }
}

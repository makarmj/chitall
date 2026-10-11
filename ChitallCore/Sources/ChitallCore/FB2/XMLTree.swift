import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A tiny read-only DOM built from `XMLParser` events. Element and attribute names are stored
/// without namespace prefixes: FB2 files use `l:href`, `xlink:href` or a prefixed default
/// namespace interchangeably, and locators must not depend on that.
final class XMLNode {
    enum Child {
        case element(XMLNode)
        case text(String, path: String)
    }

    let name: String
    let attributes: [String: String]
    /// XPath-like path over local names, e.g. `/FictionBook/body[1]/section[2]/p[5]`.
    let path: String
    private(set) var children: [Child] = []
    private var siblingCounters: [String: Int] = [:]
    private var textCounter = 0

    init(name: String, attributes: [String: String], path: String) {
        self.name = name
        self.attributes = attributes
        self.path = path
    }

    func attribute(_ name: String) -> String? { attributes[name] }

    var elements: [XMLNode] {
        children.compactMap { child in
            if case let .element(node) = child { return node }
            return nil
        }
    }

    func firstElement(named name: String) -> XMLNode? {
        for child in children {
            if case let .element(node) = child, node.name == name { return node }
        }
        return nil
    }

    func elements(named name: String) -> [XMLNode] {
        elements.filter { $0.name == name }
    }

    /// Concatenated character data of all descendants (no normalization).
    var rawText: String {
        var result = ""
        appendRawText(to: &result)
        return result
    }

    private func appendRawText(to result: inout String) {
        for child in children {
            switch child {
            case let .text(text, _): result += text
            case let .element(node): node.appendRawText(to: &result)
            }
        }
    }

    fileprivate func appendElement(name: String, attributes: [String: String]) -> XMLNode {
        let index = (siblingCounters[name] ?? 0) + 1
        siblingCounters[name] = index
        let node = XMLNode(name: name, attributes: attributes, path: "\(path)/\(name)[\(index)]")
        children.append(.element(node))
        return node
    }

    fileprivate func appendText(_ text: String) {
        textCounter += 1
        children.append(.text(text, path: "\(path)/text()[\(textCounter)]"))
    }
}

enum XMLTreeReader {
    static func read(_ utf8Data: Data) throws -> XMLNode {
        let parser = XMLParser(data: utf8Data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let builder = TreeBuilder()
        parser.delegate = builder
        let succeeded = parser.parse()
        guard succeeded, builder.failure == nil, let root = builder.root else {
            let reason = builder.failure ?? parser.parserError.map { String(describing: $0) } ?? "unknown"
            throw BookImportError.malformedXML(
                line: max(parser.lineNumber, 1),
                column: max(parser.columnNumber, 1),
                reason: reason
            )
        }
        return root
    }

    static func localName(_ qualified: String) -> String {
        guard let colon = qualified.lastIndex(of: ":") else { return qualified }
        return String(qualified[qualified.index(after: colon)...])
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: XMLNode?
    private(set) var failure: String?
    private var stack: [XMLNode] = []
    private var pendingText = ""
    private var hasPendingText = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        flushText()
        let name = XMLTreeReader.localName(elementName)
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict where key != "xmlns" && !key.hasPrefix("xmlns:") {
            attributes[XMLTreeReader.localName(key)] = value
        }
        let node: XMLNode
        if let parent = stack.last {
            node = parent.appendElement(name: name, attributes: attributes)
        } else if root == nil {
            node = XMLNode(name: name, attributes: attributes, path: "/\(name)")
            root = node
        } else {
            failure = "more than one root element"
            parser.abortParsing()
            return
        }
        stack.append(node)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        flushText()
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        pendingText += string
        hasPendingText = true
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty else { return }
        pendingText += String(decoding: CDATABlock, as: UTF8.self)
        hasPendingText = true
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        flushText()
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        flushText()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = String(describing: parseError) }
    }

    private func flushText() {
        defer {
            pendingText = ""
            hasPendingText = false
        }
        guard hasPendingText, let parent = stack.last else { return }
        parent.appendText(pendingText)
    }
}
